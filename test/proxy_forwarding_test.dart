// AC-3: the server key reaches the upstream, the client's credentials do
// not; path / model / body-size allowlists; the key never leaks back.
import 'dart:convert';

import 'package:flutter_llm_proxy/flutter_llm_proxy.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  late TestProxy proxy;
  final seenByClient = StringBuffer(); // 클라이언트가 받은 모든 본문·헤더

  setUpAll(() async {
    proxy = await TestProxy.start(
        allowedModels: const ['gpt-4o-mini'],
        maxBodyBytes: 4096,
        corsOrigins: const [
          'https://app.example.com',
        ]);
  });
  tearDownAll(() => proxy.close());

  Future<http.Response> send(String path,
      {Object? body,
      Map<String, String> headers = const {},
      bool token = true}) async {
    final r = await proxy.post(path,
        body: body,
        token: token ? proxy.issuer.token() : null,
        headers: headers);
    seenByClient
      ..write(r.body)
      ..write(r.headers);
    return r;
  }

  // 클라이언트가 몰래 보내 보는 자격 증명들 — 하나도 업스트림에 가면 안 된다.
  const clientCreds = {
    'authorization': 'Bearer client-supplied-key',
    'x-api-key': 'client-supplied-anthropic',
    'x-goog-api-key': 'client-supplied-gemini',
    'cookie': 'session=client-cookie',
  };

  test(
      'OpenAI: upstream gets Authorization: Bearer <server key>, not the client values',
      () async {
    final r = await send('/openai/v1/chat/completions',
        body: chatBody(), headers: clientCreds);
    expect(r.statusCode, 200);
    final seen = proxy.mock.requests.last.headers;
    expect(seen['authorization'], 'Bearer ${serverKeys['openai']}');
    expect(seen.containsKey('x-firebase-appcheck'), isFalse);
    expect(seen.containsKey('x-api-key'), isFalse);
    expect(seen.containsKey('x-goog-api-key'), isFalse);
    expect(seen.containsKey('cookie'), isFalse);
  });

  test('Anthropic: upstream gets x-api-key <server key>, no Authorization',
      () async {
    final r = await send('/anthropic/v1/messages',
        body: {'model': 'claude-mock', 'max_tokens': 64, 'messages': []},
        headers: {...clientCreds, 'anthropic-version': '2023-06-01'});
    expect(r.statusCode, 200);
    final seen = proxy.mock.requests.last.headers;
    expect(seen['x-api-key'], serverKeys['anthropic']);
    expect(seen.containsKey('authorization'), isFalse);
    expect(seen.containsKey('x-firebase-appcheck'), isFalse);
    expect(seen['anthropic-version'], '2023-06-01',
        reason: 'ordinary headers are passed through');
  });

  test(
      'Gemini: upstream gets x-goog-api-key, client ?key= is dropped, alt=sse kept',
      () async {
    final r = await send(
        '/gemini/v1beta/models/gemini-mock:streamGenerateContent?alt=sse&key=client-query-key',
        body: {'contents': []},
        headers: clientCreds);
    expect(r.statusCode, 200);
    final rec = proxy.mock.requests.last;
    expect(rec.headers['x-goog-api-key'], serverKeys['gemini']);
    expect(rec.headers.containsKey('authorization'), isFalse);
    expect(rec.pathAndQuery, isNot(contains('client-query-key')));
    expect(rec.pathAndQuery, contains('alt=sse'));
  });

  test(
      'path outside the allowlist -> 404 path_not_allowed; unknown prefix -> 404 unknown_route',
      () async {
    final before = proxy.mock.requests.length;
    final r1 = await send('/openai/v1/files', body: {});
    expect(r1.statusCode, 404);
    expect(proxy.errorOf(r1)['code'], 'path_not_allowed');
    final r2 =
        await send('/openai/v1/chat/completions/../../v1/files', body: {});
    expect(r2.statusCode, 404);
    final r3 = await send('/azure/v1/chat/completions', body: {});
    expect(r3.statusCode, 404);
    expect(proxy.errorOf(r3)['code'], 'unknown_route');
    expect(proxy.mock.requests.length, before, reason: 'nothing forwarded');
  });

  test('model outside the allowlist -> 403 (body model and Gemini path model)',
      () async {
    final r1 = await send('/openai/v1/chat/completions',
        body: chatBody(model: 'gpt-5-pro'));
    expect(r1.statusCode, 403);
    expect(proxy.errorOf(r1)['code'], 'model_not_allowed');
    final r2 = await send('/anthropic/v1/messages',
        body: {'model': 'claude-opus-expensive', 'messages': []});
    expect(r2.statusCode, 403);
    final r3 = await send('/gemini/v1beta/models/gemini-ultra:generateContent',
        body: {'contents': []});
    expect(r3.statusCode, 403);
    expect(proxy.errorOf(r3)['code'], 'model_not_allowed');
    final r4 = await send('/openai/v1/chat/completions', body: 'not json');
    expect(r4.statusCode, 400);
  });

  test(
      'allowlist patterns: * stays inside one segment; dot segments and %-escapes never match',
      () {
    const p = '/v1beta/models/*:streamGenerateContent';
    expect(
        pathAllowed(p, '/v1beta/models/gemini-2.0-flash:streamGenerateContent'),
        isTrue);
    expect(pathAllowed(p, '/v1beta/models/a/b:streamGenerateContent'), isFalse);
    expect(pathAllowed(p, '/v1beta/models/..%2Ffiles:streamGenerateContent'),
        isFalse);
    expect(pathAllowed('/v1/*', '/v1/..'), isFalse);
    expect(
        pathAllowed('/v1/chat/completions', '/v1/chat/completions/'), isFalse);
  });

  test('body over max_body_bytes -> 413', () async {
    final big = chatBody()
      ..['messages'] = [
        {'role': 'user', 'content': 'x' * 5000}
      ];
    final r = await send('/openai/v1/chat/completions', body: big);
    expect(r.statusCode, 413);
    expect(proxy.errorOf(r)['code'], 'body_too_large');
  });

  test('/healthz answers without a token', () async {
    final r = await send('/healthz', body: {}, token: false);
    expect(r.statusCode, 200);
  });

  test(
      'CORS: allowed origin preflight 204 with App Check header allowed; other origin 403',
      () async {
    final pre = await proxy.client.send(
        http.Request('OPTIONS', proxy.url('/openai/v1/chat/completions'))
          ..headers['origin'] = 'https://app.example.com'
          ..headers['access-control-request-headers'] =
              'content-type, x-firebase-appcheck');
    expect(pre.statusCode, 204);
    expect(
        pre.headers['access-control-allow-origin'], 'https://app.example.com');
    expect(pre.headers['access-control-allow-headers'],
        contains('x-firebase-appcheck'));
    final bad = await proxy.client.send(
        http.Request('OPTIONS', proxy.url('/openai/v1/chat/completions'))
          ..headers['origin'] = 'https://evil.example.net');
    expect(bad.statusCode, 403);
    final real = await send('/openai/v1/chat/completions',
        body: chatBody(), headers: {'origin': 'https://app.example.com'});
    expect(
        real.headers['access-control-allow-origin'], 'https://app.example.com');
  });

  test(
      'provider without a server key -> 500 server_key_missing (nothing forwarded)',
      () async {
    final p = await TestProxy.start(keys: {'openai': serverKeys['openai']!});
    try {
      final r = await p.post('/anthropic/v1/messages',
          body: {'model': 'claude-mock'}, token: p.issuer.token());
      expect(r.statusCode, 500);
      expect(p.errorOf(r)['code'], 'server_key_missing');
      expect(p.mock.requests, isEmpty);
    } finally {
      await p.close();
    }
  });

  test('server keys never appear in responses (body, headers) or logs',
      () async {
    // 업스트림 오류 본문이 그대로 전달되는 경로까지 포함해 한 번 더 부른다.
    await send('/openai/v1/chat/completions', body: chatBody(stream: true));
    final everything = '$seenByClient\n${proxy.logs.join('\n')}';
    expect(proxy.logs, isNotEmpty);
    for (final key in serverKeys.values) {
      expect(everything, isNot(contains(key)));
    }
    // 클라이언트가 보낸 토큰·키도 로그에 남지 않는다.
    expect(proxy.logs.join('\n'), isNot(contains('client-supplied')));
    expect(proxy.logs.join('\n'), isNot(contains('client-query-key')));
  });

  test('logger redacts a known secret even if some code path tries to print it',
      () {
    final lines = <String>[];
    final logger =
        RequestLogger(sink: lines.add, secrets: ['sk-very-secret-value']);
    logger.info('serve.warning', {'text': 'oops sk-very-secret-value'});
    expect(lines.single, isNot(contains('sk-very-secret-value')));
    expect(lines.single, contains('***'));
  });

  test('error bodies use fixed English codes', () async {
    final r = await send('/openai/v1/chat/completions',
        body: chatBody(), token: false);
    expect(jsonDecode(r.body), {
      'error': {
        'type': 'proxy_error',
        'code': 'app_check_failed',
        'reason': 'missing_token'
      }
    });
  });

  test(
      'non-POST methods on an allowed path get 405 and never reach the upstream',
      () async {
    final before = proxy.mock.requests.length;
    final url = proxy.url('/openai/v1/chat/completions');
    final headers = {'x-firebase-appcheck': proxy.issuer.token()};
    for (final method in ['GET', 'PUT', 'DELETE', 'PATCH']) {
      final r = await http.Response.fromStream(await proxy.client
          .send(http.Request(method, url)..headers.addAll(headers)));
      expect(r.statusCode, 405, reason: method);
      expect(r.headers['allow'], 'POST', reason: method);
      expect(proxy.errorOf(r)['code'], 'method_not_allowed', reason: method);
    }
    expect(proxy.mock.requests.length, before,
        reason: 'upstream must see nothing');
  });
}
