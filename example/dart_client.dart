// Library use: add the proxy pieces to your own shelf server.
//
// Runs fully offline: a PRACTICE MOCK upstream (recorded-format samples,
// not a real model) and App Check tokens minted with a local test key.
//
//   dart run example/dart_client.dart
import 'dart:convert';

import 'package:flutter_llm_proxy/flutter_llm_proxy.dart';
import 'package:flutter_llm_proxy/testing.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

Future<void> main() async {
  print('PRACTICE MOCK: the upstream replays recorded samples; no API key or network is used.\n');

  // 1) Stand-ins for the outside world: a mock OpenAI and a local App Check key.
  final mock = await MockUpstream.start(chunkDelay: const Duration(milliseconds: 150));
  final issuer = AppCheckTestIssuer();

  // 2) The proxy pieces, composed in your own shelf pipeline.
  final config = ProxyConfig(
    providers: [ProviderConfig.defaults(ProviderType.openai).copyWith(upstream: mock.url)],
    appCheck: AppCheckConfig(mode: AppCheckMode.local, projectNumber: issuer.projectNumber),
  );
  final verifier = AppCheckVerifier(
    projectNumber: issuer.projectNumber,
    jwks: StaticJwksSource(issuer.jwks()), // in production: HttpJwksSource(<Firebase JWKS URL>)
  );
  final limiter = RateLimiter(requestsPerMinute: 10, tokensPerDay: 10000);
  final handler = const Pipeline()
      .addMiddleware(appCheckMiddleware(verifier))
      .addMiddleware(rateLimitMiddleware(limiter, SubjectKey.app))
      .addHandler(llmProxyHandler(
        config,
        serverKeys: {'openai': 'sk-example-server-key'}, // in production: from the environment
        onUsage: (request, provider, result) {
          final subject = request.context[subjectContextKey] as String;
          limiter.addTokens(subject, result.usage.totalTokens);
          print('\n[proxy] ${provider.id} usage: ${result.usage}');
        },
      ));
  final server = await shelf_io.serve(handler, '127.0.0.1', 0);

  // 3) What a Flutter app does: attach the App Check token, call the proxy
  //    instead of api.openai.com, read the stream as it arrives.
  final client = http.Client();
  try {
    final request = http.Request('POST', Uri.parse('http://127.0.0.1:${server.port}/openai/v1/chat/completions'))
      ..headers['content-type'] = 'application/json'
      ..headers['x-firebase-appcheck'] = issuer.token()
      ..body = jsonEncode({
        'model': 'gpt-4o-mini',
        'stream': true,
        'messages': [
          {'role': 'user', 'content': 'Say hello'}
        ],
      });
    final response = await client.send(request);
    print('[app] HTTP ${response.statusCode}, streaming:');

    final lines = response.stream.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (!line.startsWith('data: ') || line == 'data: [DONE]') continue;
      final chunk = jsonDecode(line.substring(6)) as Map<String, dynamic>;
      final choices = chunk['choices'] as List<dynamic>;
      if (choices.isEmpty) continue; // the last chunk only carries usage
      final delta = (choices.first as Map<String, dynamic>)['delta'] as Map<String, dynamic>;
      print('[app]   token: "${delta['content'] ?? ''}"');
    }

    final seen = mock.requests.last.headers;
    print('[mock upstream] got server key: ${seen['authorization'] == 'Bearer sk-example-server-key'}, '
        'got App Check token: ${seen.containsKey('x-firebase-appcheck')}');
  } finally {
    client.close();
    await server.close(force: true);
    await mock.close();
  }
}
