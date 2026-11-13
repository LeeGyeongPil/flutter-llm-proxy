import 'package:shelf/shelf.dart';

import '../proxy/errors.dart';

/// CORS for Flutter web. Only origins in [allowOrigins] get CORS headers
/// (`*` allows any origin — check-config warns about it).
///
/// Preflight (`OPTIONS`) requests are answered here, before App Check,
/// because browsers never attach custom headers to a preflight.
Middleware corsMiddleware(List<String> allowOrigins) {
  const allowHeaders =
      'content-type, x-firebase-appcheck, anthropic-version, anthropic-beta';
  bool allowed(String origin) =>
      allowOrigins.contains('*') || allowOrigins.contains(origin);

  Map<String, String> headersFor(String origin) => {
        'access-control-allow-origin': origin,
        'access-control-expose-headers': 'retry-after',
        'vary': 'Origin',
      };

  return (Handler inner) {
    return (Request request) async {
      final origin = request.headers['origin'];
      if (request.method == 'OPTIONS') {
        if (origin == null || !allowed(origin)) {
          return proxyError(403, 'cors_origin_not_allowed');
        }
        return Response(204, headers: {
          ...headersFor(origin),
          'access-control-allow-methods': 'POST, OPTIONS',
          'access-control-allow-headers': allowHeaders,
          'access-control-max-age': '600',
        });
      }
      final response = await inner(request);
      if (origin != null && allowed(origin)) {
        return response.change(headers: headersFor(origin));
      }
      return response;
    };
  };
}
