import 'dart:io';

import 'package:shelf/shelf.dart';

import '../config.dart';
import '../log.dart';
import 'errors.dart';
import 'forwarder.dart';

/// True when [path] matches an allowlist [pattern]. `*` matches any text
/// inside one path segment (never a `/`), e.g.
/// `/v1beta/models/*:streamGenerateContent`.
bool pathAllowed(String pattern, String path) {
  // 점 경로(.., .)·퍼센트 인코딩으로 허용 목록을 빠져나가는 시도는 처음부터 거절한다.
  final segments = path.split('/');
  if (segments.any((s) => s == '..' || s == '.')) return false;
  final regex =
      RegExp('^${RegExp.escape(pattern).replaceAll(r'\*', '[^/%]*')}\$');
  return regex.hasMatch(path);
}

/// Reads each provider's key from the environment variable named in the
/// config. Providers whose variable is unset are left out.
Map<String, String> serverKeysFromEnvironment(ProxyConfig config,
    [Map<String, String>? env]) {
  final e = env ?? Platform.environment;
  return {
    for (final p in config.providers)
      if ((e[p.keyEnv] ?? '').isNotEmpty) p.id: e[p.keyEnv]!,
  };
}

/// The forwarding part of the proxy (no attestation or limits — add those
/// with [appCheckMiddleware] / [rateLimitMiddleware], or use
/// `buildProxyHandler` for the whole pipeline).
///
/// `/<prefix>/<upstream path>` goes to that provider's upstream if the path
/// is on its allowlist and the method is POST; other methods get 405
/// (`Allow: POST`), anything else is 404.
Handler llmProxyHandler(
  ProxyConfig config, {
  UpstreamClientFactory? clientFactory,
  UsageSink? onUsage,
  Map<String, String>? serverKeys,
  bool bufferOutput = false,
}) {
  final keys = serverKeys ?? serverKeysFromEnvironment(config);
  final forwarders = <ProviderConfig, Forwarder?>{
    for (final p in config.providers)
      p: keys[p.id] == null
          ? null
          : Forwarder(
              p,
              serverKey: keys[p.id]!,
              maxBodyBytes: config.maxBodyBytes,
              clientFactory: clientFactory,
              onUsage: onUsage,
              bufferOutput: bufferOutput,
            ),
  };

  return (Request request) {
    final stats = request.context[statsContextKey] as RequestStats?;
    final path = '/${request.url.path}';
    for (final provider in config.providers) {
      if (path != provider.prefix && !path.startsWith('${provider.prefix}/'))
        continue;
      final upstreamPath = path.substring(provider.prefix.length);
      if (!provider.allowedPaths.any((p) => pathAllowed(p, upstreamPath))) {
        stats?.reason = 'path_not_allowed';
        return proxyError(404, 'path_not_allowed');
      }
      // LLM 호출은 POST 뿐이다. GET 등은 서버 키로 계정의 다른 자원을 읽을 수 있으므로 보내지 않는다.
      if (request.method != 'POST') {
        stats?.reason = 'method_not_allowed';
        return proxyError(405, 'method_not_allowed',
            headers: {'allow': 'POST'});
      }
      final forwarder = forwarders[provider];
      if (forwarder == null) {
        stats?.reason = 'server_key_missing';
        return proxyError(500, 'server_key_missing');
      }
      return forwarder.forward(request, upstreamPath);
    }
    stats?.reason = 'unknown_route';
    return proxyError(404, 'unknown_route');
  };
}
