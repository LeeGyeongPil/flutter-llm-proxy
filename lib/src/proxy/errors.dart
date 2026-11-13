import 'dart:convert';

import 'package:shelf/shelf.dart';

/// Context key where the App Check middleware stores [AppCheckClaims].
const String appCheckContextKey = 'flutter_llm_proxy.app_check';

/// Context key for the per-request [RequestStats] (see log.dart).
const String statsContextKey = 'flutter_llm_proxy.stats';

/// Context key for the rate-limit subject string.
const String subjectContextKey = 'flutter_llm_proxy.subject';

/// Error body clients can match on. Codes are fixed English keys on purpose
/// (they are an API, not UI text):
/// `{"error":{"type":"proxy_error","code":"app_check_failed","reason":"bad_aud"}}`
Response proxyError(int status, String code,
    {String? reason, Map<String, String> headers = const {}}) {
  return Response(
    status,
    body: jsonEncode({
      'error': {
        'type': 'proxy_error',
        'code': code,
        if (reason != null) 'reason': reason,
      }
    }),
    headers: {'content-type': 'application/json', ...headers},
  );
}
