// Shared setup for the HTTP-level tests: a real proxy on 127.0.0.1:<random>,
// the practice mock upstream, and App Check tokens from a local test key.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_llm_proxy/flutter_llm_proxy.dart';
import 'package:flutter_llm_proxy/testing.dart';
import 'package:http/http.dart' as http;

/// Fake server keys. Tests assert none of them ever reaches a client or a log.
const serverKeys = {
  'openai': 'sk-test-openai-SERVER-ONLY-111',
  'anthropic': 'sk-ant-test-SERVER-ONLY-222',
  'gemini': 'gm-test-SERVER-ONLY-333',
};

/// RSA key generation takes a moment; share one issuer per test file.
AppCheckTestIssuer? _issuer;
AppCheckTestIssuer get sharedIssuer => _issuer ??= AppCheckTestIssuer();

/// A clock the test moves by hand.
class FakeClock {
  FakeClock([DateTime? start])
      : now = start ?? DateTime.utc(2026, 11, 14, 12, 0, 10);
  DateTime now;
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

class TestProxy {
  TestProxy._(this.app, this.server, this.mock, this.logs, this.issuer);

  final ProxyApp app;
  final HttpServer server;
  final MockUpstream mock;
  final List<String> logs;
  final AppCheckTestIssuer issuer;
  final client = http.Client();

  Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  static Future<TestProxy> start({
    Duration chunkDelay = const Duration(milliseconds: 20),
    Map<ProviderType, String>? fixtures,
    bool bufferOutput = false,
    LimitsConfig limits = const LimitsConfig(),
    List<String> allowedModels = const [],
    bool injectIncludeUsage = true,
    int maxBodyBytes = 1024 * 1024,
    bool trustForwardedFor = false,
    List<String> corsOrigins = const [],
    Set<String>? allowedAppIds,
    Map<String, String>? keys,
    Clock? clock,
    AppCheckTestIssuer? issuer,
  }) async {
    final iss = issuer ?? sharedIssuer;
    final mock =
        await MockUpstream.start(chunkDelay: chunkDelay, fixtures: fixtures);
    ProviderConfig p(ProviderType t, List<String> models) =>
        ProviderConfig.defaults(t)
            .copyWith(upstream: mock.url)
            .withModels(models, injectIncludeUsage);
    final config = ProxyConfig(
      providers: [
        p(ProviderType.openai,
            allowedModels.isEmpty ? const [] : allowedModels),
        p(ProviderType.anthropic,
            allowedModels.isEmpty ? const [] : const ['claude-mock']),
        p(ProviderType.gemini,
            allowedModels.isEmpty ? const [] : const ['gemini-mock']),
      ],
      appCheck: AppCheckConfig(
        mode: AppCheckMode.local,
        projectNumber: iss.projectNumber,
        projectId: iss.projectId,
        allowedAppIds: allowedAppIds ?? {iss.appId},
      ),
      limits: limits,
      maxBodyBytes: maxBodyBytes,
      trustForwardedFor: trustForwardedFor,
      corsAllowOrigins: corsOrigins,
    );
    final logs = <String>[];
    final app = ProxyApp(
      config,
      jwks: StaticJwksSource(iss.jwks()),
      serverKeys: keys ?? serverKeys,
      logger: RequestLogger(sink: logs.add),
      bufferOutput: bufferOutput,
      clock: clock,
    );
    final server = await app.serve(host: '127.0.0.1', port: 0);
    return TestProxy._(app, server, mock, logs, iss);
  }

  /// POST JSON and read the whole reply.
  Future<http.Response> post(String path,
      {Object? body, String? token, Map<String, String> headers = const {}}) {
    return client.post(
      url(path),
      headers: {
        'content-type': 'application/json',
        if (token != null) 'x-firebase-appcheck': token,
        ...headers,
      },
      body: body is String ? body : jsonEncode(body ?? {}),
    );
  }

  Map<String, Object?> errorOf(http.Response r) =>
      ((jsonDecode(r.body) as Map<String, Object?>)['error']
          as Map<String, Object?>?) ??
      {};

  Future<void> close() async {
    client.close();
    await server.close(force: true);
    await mock.close();
  }
}

extension on ProviderConfig {
  ProviderConfig withModels(List<String> models, bool inject) => ProviderConfig(
        id: id,
        type: type,
        prefix: prefix,
        upstream: upstream,
        keyEnv: keyEnv,
        keyHeader: keyHeader,
        allowedPaths: allowedPaths,
        allowedModels: models,
        injectIncludeUsage: inject,
      );
}

/// Request body for an OpenAI-style chat call.
Map<String, Object?> chatBody(
        {String model = 'gpt-4o-mini',
        bool stream = false,
        Map<String, Object?>? streamOptions}) =>
    {
      'model': model,
      'stream': stream,
      if (streamOptions != null) 'stream_options': streamOptions,
      'messages': [
        {'role': 'user', 'content': 'hi'}
      ],
    };

final hangul = RegExp('[가-힣]');
