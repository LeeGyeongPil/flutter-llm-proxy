import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'app_check/jwks.dart';
import 'app_check/verifier.dart';
import 'clock.dart';
import 'config.dart';
import 'log.dart';
import 'middleware/app_check_middleware.dart';
import 'middleware/cors.dart';
import 'middleware/rate_limit.dart';
import 'proxy/errors.dart' show subjectContextKey;
import 'proxy/forwarder.dart';
import 'proxy/router.dart';

/// The whole proxy, assembled from a [ProxyConfig]:
///
/// log -> CORS -> /healthz -> App Check -> rate limit -> forward (+ usage tap)
///
/// Every part is also exported on its own for people who already have a
/// shelf server.
class ProxyApp {
  ProxyApp(
    this.config, {
    JwksSource? jwks,
    Map<String, String>? serverKeys,
    UpstreamClientFactory? clientFactory,
    RequestLogger? logger,
    RateLimiter? limiter,
    UsageSink? onUsage,
    Clock? clock,
    bool bufferOutput = false,
  }) {
    final keys = serverKeys ?? serverKeysFromEnvironment(config);
    this.logger = logger ?? RequestLogger();
    // 서버 키·개발용 토큰은 로그에 절대 찍히지 않도록 가림 목록에 넣는다.
    keys.values.forEach(this.logger.addSecret);
    config.appCheck.devTokens.forEach(this.logger.addSecret);

    this.limiter = limiter ??
        RateLimiter(
          requestsPerMinute: config.limits.requestsPerMinute,
          tokensPerDay: config.limits.tokensPerDay,
          globalTokensPerDay: config.limits.globalTokensPerDay,
          clock: clock,
        );

    final forward = llmProxyHandler(
      config,
      clientFactory: clientFactory,
      serverKeys: keys,
      bufferOutput: bufferOutput,
      onUsage: (request, provider, usage) {
        // 응답이 끝난 뒤 실제 사용 토큰을 일일 예산에서 뺀다.
        final subject = request.context[subjectContextKey] as String?;
        if (subject != null)
          this.limiter.addTokens(subject, usage.usage.totalTokens);
        onUsage?.call(request, provider, usage);
      },
    );

    var pipeline = const Pipeline()
        .addMiddleware(this.logger.middleware())
        .addMiddleware(corsMiddleware(config.corsAllowOrigins))
        .addMiddleware(_healthz);
    if (config.appCheck.mode != AppCheckMode.off) {
      final verifier = AppCheckVerifier(
        projectNumber: config.appCheck.projectNumber,
        projectId: config.appCheck.projectId,
        allowedAppIds: config.appCheck.allowedAppIds,
        jwks: jwks ?? jwksSourceFor(config, clock: clock),
        clock: clock,
      );
      pipeline = pipeline.addMiddleware(
          appCheckMiddleware(verifier, devTokens: config.appCheck.devTokens));
    }
    pipeline = pipeline.addMiddleware(rateLimitMiddleware(
        this.limiter, config.limits.subject,
        trustForwardedFor: config.trustForwardedFor));
    handler = pipeline.addHandler(forward);
  }

  final ProxyConfig config;
  late final Handler handler;
  late final RateLimiter limiter;
  late final RequestLogger logger;

  /// Starts listening. Default host is loopback only.
  Future<HttpServer> serve({String host = '127.0.0.1', int port = 8080}) =>
      shelf_io.serve(handler, host, port);
}

/// JWKS source for the configured App Check mode.
JwksSource jwksSourceFor(ProxyConfig config, {Clock? clock}) {
  final ac = config.appCheck;
  if (ac.mode == AppCheckMode.local && ac.jwksFile != null) {
    // 설정 파일 기준 상대 경로
    var path = ac.jwksFile!;
    if (!File(path).isAbsolute) {
      final dir = File(config.sourceName).parent.path;
      path = '$dir${Platform.pathSeparator}$path';
    }
    return StaticJwksSource(
        jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>);
  }
  return HttpJwksSource(ac.jwksUrl, clock: clock);
}

Handler _healthz(Handler inner) {
  return (Request request) {
    if (request.url.path == 'healthz') {
      return Response.ok('{"status":"ok"}',
          headers: {'content-type': 'application/json'});
    }
    return inner(request);
  };
}

/// Loopback hosts where dev tokens / `mode: off` are tolerated.
bool isLoopbackHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h == '::1' || h == '[::1]') return true;
  final ip = InternetAddress.tryParse(h);
  return ip != null && ip.isLoopback;
}
