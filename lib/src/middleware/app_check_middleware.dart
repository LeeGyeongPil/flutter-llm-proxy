import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../app_check/verifier.dart';
import '../log.dart';
import '../proxy/errors.dart';

/// Header Firebase clients send the App Check token in.
const String appCheckHeader = 'x-firebase-appcheck';

/// App ID recorded for requests that used a development token.
const String devTokenAppId = 'dev-token';

/// Rejects requests without a valid App Check token (401) and stores the
/// verified claims in `request.context['flutter_llm_proxy.app_check']`.
///
/// [devTokens] are fixed strings accepted instead of a token — for local
/// testing with curl only. `serve` refuses them on a non-loopback host.
Middleware appCheckMiddleware(AppCheckVerifier verifier,
    {List<String> devTokens = const []}) {
  return (Handler inner) {
    return (Request request) async {
      final token = request.headers[appCheckHeader];
      final stats = request.context[statsContextKey] as RequestStats?;

      AppCheckClaims claims;
      if (token != null &&
          devTokens.any((d) => _constantTimeEquals(d, token))) {
        claims = AppCheckClaims(
            appId: devTokenAppId,
            audience: const [],
            expiresAt: DateTime.utc(9999));
      } else {
        try {
          claims = await verifier.verify(token);
        } on AppCheckException catch (e) {
          stats?.reason = e.reason.code;
          if (e.reason == AppCheckFailure.jwksUnavailable) {
            return proxyError(503, 'app_check_unavailable',
                reason: e.reason.code);
          }
          return proxyError(401, 'app_check_failed', reason: e.reason.code);
        }
      }
      return inner(request.change(context: {appCheckContextKey: claims}));
    };
  };
}

/// Compares without stopping at the first different byte, so response time
/// does not reveal how much of a guessed dev token was right.
bool _constantTimeEquals(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  var diff = x.length ^ y.length;
  for (var i = 0; i < x.length; i++) {
    diff |= x[i] ^ (i < y.length ? y[i] : 0);
  }
  return diff == 0;
}
