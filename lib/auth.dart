import 'dart:convert';

import 'package:bluesky/bluesky.dart' as bsky;
import 'package:dart_frog/dart_frog.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:http/http.dart' as http;
import 'package:sky_bridge/crypto.dart';
import 'package:sky_bridge/database.dart';
import 'package:sky_bridge/models/oauth/oauth_access_token.dart';
import 'package:sky_bridge/models/preferences.dart';
import 'package:sky_bridge/src/generated/prisma/prisma_client.dart';

/// Global client
final httpClient = http.Client();

/// Takes an IP address and ensures that authentication attempts are not
/// being made too frequently. Bluesky now has quite aggressive rate limiting
/// for authentication attempts, so we have to do the same.
///
/// Returns true if the IP has hit the rate limit, false otherwise.
Future<void> incrementFailedAuthAttempt(RequestContext context) async {
  final ip = context.request.headers['X-Forwarded-For'] ??
      context.request.connectionInfo.remoteAddress.address;

  // Check if we already have a rate limit for this IP in the database.
  await db.authRateLimit.upsert(
    where: AuthRateLimitWhereUniqueInput(
      ipAddress: ip,
    ),
    create: AuthRateLimitCreateInput(
      ipAddress: ip,
      attempts: 1,
    ),
    update: const AuthRateLimitUpdateInput(
      attempts: IntFieldUpdateOperationsInput(
        increment: 1,
      ),
    ),
  );
}

/// Determines if an IP address has hit the rate limit for authentication.
Future<bool> isIpRateLimited(RequestContext context) async {
  final ip = context.request.headers['X-Forwarded-For'] ??
      context.request.connectionInfo.remoteAddress.address;

  final limit = await db.authRateLimit.findUnique(
    where: AuthRateLimitWhereUniqueInput(
      ipAddress: ip,
    ),
  );
  if (limit == null) return false;

  // We've hit the rate limit.
  if (limit.attempts >= 5) {
    final now = DateTime.now().toUtc();

    // If the last time the limit was hit is null, set it to now.
    if (limit.lastAttempt == null) {
      await db.authRateLimit.update(
        where: AuthRateLimitWhereUniqueInput(
          ipAddress: ip,
        ),
        data: AuthRateLimitUpdateInput(
          lastAttempt: NullableDateTimeFieldUpdateOperationsInput(
            set: now,
          ),
        ),
      );
    }

    // If the last hit was more than 30 minutes ago, reset the limit.
    final diff = now.difference(limit.lastAttempt ?? now);
    if (diff.inMinutes > 30) {
      await db.authRateLimit.update(
        where: AuthRateLimitWhereUniqueInput(
          ipAddress: ip,
        ),
        data: AuthRateLimitUpdateInput(
          attempts: const IntFieldUpdateOperationsInput(
            set: 1,
          ),
          lastAttempt: NullableDateTimeFieldUpdateOperationsInput(
            set: now,
          ),
        ),
      );
    }
  }

  return limit.lastAttempt != null;
}

/// Reset the rate limit for a given IP address.
Future<void> resetIpRateLimit(RequestContext context) async {
  final ip = context.request.headers['X-Forwarded-For'] ??
      context.request.connectionInfo.remoteAddress.address;

  // Check if we already have a rate limit for this IP in the database.
  // If we do, delete it.
  final record = await db.authRateLimit.findUnique(
    where: AuthRateLimitWhereUniqueInput(
      ipAddress: ip,
    ),
  );

  if (record != null) {
    await db.authRateLimit.delete(
      where: AuthRateLimitWhereUniqueInput(
        ipAddress: ip,
      ),
    );
  }
}

/// Check a request context for a valid bearer token to determine if the
/// request is authenticated.
Future<bsky.Session?> sessionFromContext(RequestContext context) async {
  final header = context.request.headers['Authorization'];
  final token = validateBearerToken(header);

  // Either we don't have a token or it's in an invalid format.
  if (token == null) return null;

  // Check if we have a session for the given DID.
  final record = await db.sessionRecord.findUnique(
    where: SessionRecordWhereUniqueInput(did: token.did),
  );

  // If we already have a session then great! Otherwise, try to create one.
  if (record != null) {
    final json = jsonDecode(record.session) as Map<String, dynamic>;
    final session = bsky.Session.fromJson(json);

    final accessJwt =
        JWT.decode(session.accessJwt).payload as Map<String, dynamic>;
    final refreshJwt =
        JWT.decode(session.refreshJwt).payload as Map<String, dynamic>;

    final accessExp = DateTime.fromMillisecondsSinceEpoch(
      (accessJwt['exp'] as int) * 1000,
    );

    final refreshExp = DateTime.fromMillisecondsSinceEpoch(
      (refreshJwt['exp'] as int) * 1000,
    );
    final now = DateTime.now().toUtc();

    // Let's handle token expiration.
    if (now.isAfter(accessExp)) {
      if (now.isAfter(refreshExp)) {
        // Refresh token is expired. We gotta get a brand new session.
        // Check if the IP is rate limited for authentication attempts.
        final isRateLimited = await isIpRateLimited(context);
        if (isRateLimited) return null;

        final newSession = await createBlueskySession(
          identifier: token.identifier,
          appPassword: token.appPassword,
        );

        // Credentials are just straight up invalid. Bail.
        if (newSession == null) {
          await incrementFailedAuthAttempt(context);
          return null;
        }

        // Reset the IP rate limit.
        await resetIpRateLimit(context);

        return newSession;
      } else {
        // The access token is expired but we have a valid refresh token,
        // try to refresh the session.
        final refreshedSession = await bsky.refreshSession(
          refreshJwt: session.refreshJwt,
          mockedPostClient: httpClient.post,
          service: 'pds.dlun.ch',
        );

        // Update the session in the database.
        await db.sessionRecord.update(
          where: SessionRecordWhereUniqueInput(
            did: refreshedSession.data.did,
          ),
          data: SessionRecordUpdateInput(
            session: StringFieldUpdateOperationsInput(
              set: jsonEncode(refreshedSession.data.toJson()),
            ),
          ),
        );

        return refreshedSession.data;
      }
    }

    return session;
  } else {
    // Check if the IP is rate limited for authentication attempts.
    final isRateLimited = await isIpRateLimited(context);
    if (isRateLimited) return null;

    final newSession = await createBlueskySession(
      identifier: token.identifier,
      appPassword: token.appPassword,
    );

    // Credentials are just straight up invalid. Bail.
    if (newSession == null) {
      incrementFailedAuthAttempt(context);
      return null;
    }

    // Reset the IP rate limit.
    await resetIpRateLimit(context);

    return newSession;
  }
}

/// Helper function that takes a [RequestContext] and returns user preferences.
SkybridgePreferences preferencesFromContext(RequestContext context) {
  final header = context.request.headers['Authorization'];
  final token = validateBearerToken(header);
  if (token == null) return const SkybridgePreferences();
  return token.preferences;
}

/// Helper function that takes a [RequestContext] and returns an API accessor.
Future<bsky.Bluesky?> blueskyFromContext(RequestContext context) async {
  final session = await sessionFromContext(context);
  if (session == null) return null;
  return bsky.Bluesky.fromSession(
    session,
    mockedGetClient: httpClient.get,
    mockedPostClient: httpClient.post,
    service: 'pds.dlun.ch',
  );
}

/// A helper function to return a 401 response for an invalid bearer token.
Response authError() {
  return Response.json(
    statusCode: 401,
    body: {
      'error': 'The access token is invalid',
    },
  );
}

/// Check if [tokenString] is a valid signed bearer token that we can unpack.
OAuthAccessToken? validateBearerToken(String? tokenString) {
  if (tokenString == null) return null;
  if (tokenString.startsWith('Bearer ')) {
    final token = unpackObject(tokenString.substring(7));
    if (token == null) return null;
    return OAuthAccessToken.fromJson(token);
  }
  return null;
}

/// Global list of active sessions.
Map<String, bsky.Session> sessions = {};

/// Create a Bluesky session with the given credentials and store
/// it in [sessions].
Future<bsky.Session?> createBlueskySession({
  required String identifier,
  required String appPassword,
}) async {
  try {
    // Try to authenticate with Bluesky with the given credentials.
    final session = await bsky.createSession(
      identifier: identifier,
      password: appPassword,
      mockedPostClient: httpClient.post,
      service: 'pds.dlun.ch',
    );

    // If we've gotten this far, the credentials are valid.
    // Store the session in the global list for later.
    await db.sessionRecord.upsert(
      where: SessionRecordWhereUniqueInput(
        did: session.data.did,
      ),
      create: SessionRecordCreateInput(
        did: session.data.did,
        session: jsonEncode(session.data.toJson()),
      ),
      update: SessionRecordUpdateInput(
        session: StringFieldUpdateOperationsInput(
          set: jsonEncode(session.data.toJson()),
        ),
      ),
    );
    print('New session created for ${session.data.did}');
    return session.data;
  } catch (e) {
    return null;
  }
}
