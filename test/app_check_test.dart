// AC-2: App Check verification — valid token passes, every kind of bad
// token gets 401 with its reason, and the JWKS refetch rules hold.
import 'dart:convert';
import 'dart:io';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:flutter_llm_proxy/flutter_llm_proxy.dart';
import 'package:flutter_llm_proxy/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  late TestProxy proxy;
  late AppCheckTestIssuer issuer;

  setUpAll(() async {
    proxy = await TestProxy.start();
    issuer = proxy.issuer;
  });
  tearDownAll(() => proxy.close());

  test('valid token with a 2-item aud list is accepted (200)', () async {
    final r = await proxy.post('/openai/v1/chat/completions',
        body: chatBody(), token: issuer.token());
    expect(r.statusCode, 200);
    expect(issuer.token().split('.').length, 3);
  });

  group('rejected with 401 and a reason', () {
    final cases = <String, String? Function()>{
      'missing_token': () => null,
      'malformed': () => 'not-a-jwt',
      'alg_not_rs256 (HS256 forged with the public key)': () =>
          issuer.forgeHs256(),
      'alg_not_rs256 (alg none)': () => issuer.algNone(),
      'unknown_kid': () => issuer.token(kid: 'some-other-key'),
      'bad_signature': () => issuer.tampered(),
      'expired': () => issuer.token(expiresIn: const Duration(seconds: -1)),
      'bad_iss': () => issuer.token(
          issuer: 'https://firebaseappcheck.googleapis.com/999999999999'),
      'bad_aud': () => issuer.token(
          audience: ['projects/999999999999', 'projects/${issuer.projectId}']),
      'app_not_allowed': () => issuer.token(
          appId: '1:${issuer.projectNumber}:android:not-in-the-list'),
    };
    cases.forEach((name, makeToken) {
      test(name, () async {
        final expected = name.split(' ').first;
        final r = await proxy.post('/openai/v1/chat/completions',
            body: chatBody(), token: makeToken());
        expect(r.statusCode, 401);
        expect(proxy.errorOf(r), {
          'type': 'proxy_error',
          'code': 'app_check_failed',
          'reason': expected
        });
      });
    });

    test('rejected requests never reach the upstream', () {
      // 10 rejected + 1 valid call above: the mock only saw the valid one.
      expect(proxy.mock.requests.length, 1);
    });
  });

  test('aud only needs to CONTAIN projects/<number> (a 1-item list also works)',
      () async {
    final v = AppCheckVerifier(
        projectNumber: issuer.projectNumber,
        jwks: StaticJwksSource(issuer.jwks()));
    final claims = await v
        .verify(issuer.token(audience: ['projects/${issuer.projectNumber}']));
    expect(claims.appId, issuer.appId);
  });

  test(
      'pitfall: the library "audience equals" check rejects the real 2-item aud',
      () {
    final key = parseJwks(issuer.jwks())[issuer.kid]!;
    expect(
      () => JWT.verify(issuer.token(), key,
          audience: Audience.one('projects/${issuer.projectNumber}')),
      throwsA(isA<JWTInvalidException>()),
    );
  });

  test('expiry uses the injected clock', () async {
    final clock = FakeClock(DateTime.now().toUtc());
    final v = AppCheckVerifier(
        projectNumber: issuer.projectNumber,
        jwks: StaticJwksSource(issuer.jwks()),
        clock: clock.call);
    final token = issuer.token(expiresIn: const Duration(minutes: 30));
    await v.verify(token);
    clock.advance(const Duration(minutes: 31));
    await expectLater(
        v.verify(token),
        throwsA(isA<AppCheckException>()
            .having((e) => e.reason, 'reason', AppCheckFailure.expired)));
  });

  group('HttpJwksSource', () {
    late HttpServer jwksServer;
    var hits = 0;
    var body = '';
    var status = 200;
    var cacheControl = 'public, max-age=21600';

    setUp(() async {
      hits = 0;
      status = 200;
      body = jsonEncode(issuer.jwks());
      cacheControl = 'public, max-age=21600';
      jwksServer = await shelf_io.serve((Request r) {
        hits++;
        return Response(status,
            body: body, headers: {'cache-control': cacheControl});
      }, '127.0.0.1', 0);
    });
    tearDown(() => jwksServer.close(force: true));

    Uri jwksUrl() => Uri.parse('http://127.0.0.1:${jwksServer.port}/v1/jwks');

    test(
        'unknown kid refetches once; a second unknown kid within the interval does not',
        () async {
      final clock = FakeClock(DateTime.now().toUtc());
      final jwks = HttpJwksSource(jwksUrl(), clock: clock.call);
      final v = AppCheckVerifier(
          projectNumber: issuer.projectNumber, jwks: jwks, clock: clock.call);

      await v.verify(issuer.token()); // 첫 조회
      expect(jwks.fetchCount, 1);

      clock.advance(const Duration(minutes: 2));
      await expectLater(v.verify(issuer.token(kid: 'rotated-1')),
          throwsA(isA<AppCheckException>()));
      expect(jwks.fetchCount, 2, reason: 'unknown kid -> one refetch');

      clock.advance(const Duration(seconds: 5));
      await expectLater(
          v.verify(issuer.token(kid: 'rotated-2')),
          throwsA(isA<AppCheckException>()
              .having((e) => e.reason, 'reason', AppCheckFailure.unknownKid)));
      expect(jwks.fetchCount, 2,
          reason: 'within minRefetchInterval -> no refetch');

      clock.advance(const Duration(seconds: 60));
      await expectLater(v.verify(issuer.token(kid: 'rotated-3')),
          throwsA(isA<AppCheckException>()));
      expect(jwks.fetchCount, 3);
      expect(hits, 3);
    });

    test('key rotation: a new kid published later is picked up by the refetch',
        () async {
      final clock = FakeClock(DateTime.now().toUtc());
      final jwks = HttpJwksSource(jwksUrl(), clock: clock.call);
      final v = AppCheckVerifier(
          projectNumber: issuer.projectNumber, jwks: jwks, clock: clock.call);
      await v.verify(issuer.token());

      final next = AppCheckTestIssuer(
          projectNumber: issuer.projectNumber, kid: 'next-key');
      body = jsonEncode({
        'keys': [issuer.publicJwk(), next.publicJwk()]
      });
      clock.advance(const Duration(minutes: 5));
      final claims = await v.verify(next.token());
      expect(claims.appId, next.appId);
      expect(jwks.fetchCount, 2);
    });

    test('cache lifetime is min(Cache-Control max-age, 6h)', () async {
      final clock = FakeClock(DateTime.now().toUtc());
      cacheControl = 'public, max-age=100';
      final short = HttpJwksSource(jwksUrl(), clock: clock.call);
      await short.keyFor(issuer.kid);
      clock.advance(const Duration(seconds: 99));
      await short.keyFor(issuer.kid);
      expect(short.fetchCount, 1);
      clock.advance(const Duration(seconds: 2));
      await short.keyFor(issuer.kid);
      expect(short.fetchCount, 2);

      cacheControl = 'public, max-age=999999';
      final capped = HttpJwksSource(jwksUrl(), clock: clock.call);
      await capped.keyFor(issuer.kid);
      clock.advance(const Duration(hours: 5, minutes: 59));
      await capped.keyFor(issuer.kid);
      expect(capped.fetchCount, 1);
      clock.advance(const Duration(minutes: 2));
      await capped.keyFor(issuer.kid);
      expect(capped.fetchCount, 2, reason: 'never cached longer than 6 hours');
    });

    test('a failed refetch keeps the old keys', () async {
      final clock = FakeClock(DateTime.now().toUtc());
      final jwks = HttpJwksSource(jwksUrl(), clock: clock.call);
      final v = AppCheckVerifier(
          projectNumber: issuer.projectNumber, jwks: jwks, clock: clock.call);
      await v.verify(issuer.token());
      status = 500;
      clock.advance(const Duration(hours: 7)); // 캐시 만료 → 재조회 실패
      // 발급기는 실제 시계를 쓰므로, 7시간 뒤에도 유효하도록 긴 토큰을 쓴다.
      final claims =
          await v.verify(issuer.token(expiresIn: const Duration(hours: 8)));
      expect(claims.appId, issuer.appId);
      expect(jwks.fetchCount, 2);
    });

    test('no keys at all -> 503 app_check_unavailable, not 401', () async {
      status = 500;
      final p = await TestProxy.start();
      final app = ProxyApp(
        ProxyConfig(
          providers: [
            ProviderConfig.defaults(ProviderType.openai)
                .copyWith(upstream: p.mock.url)
          ],
          appCheck: AppCheckConfig(
              mode: AppCheckMode.local,
              projectNumber: issuer.projectNumber,
              jwksUrl: jwksUrl()),
        ),
        serverKeys: serverKeys,
        logger: RequestLogger(sink: (_) {}),
      );
      final server = await app.serve(host: '127.0.0.1', port: 0);
      try {
        final r = await p.client.post(
            Uri.parse(
                'http://127.0.0.1:${server.port}/openai/v1/chat/completions'),
            headers: {'x-firebase-appcheck': issuer.token()},
            body: jsonEncode(chatBody()));
        expect(r.statusCode, 503);
        expect(jsonDecode(r.body), {
          'error': {
            'type': 'proxy_error',
            'code': 'app_check_unavailable',
            'reason': 'jwks_unavailable'
          }
        });
      } finally {
        await server.close(force: true);
        await p.close();
      }
    });
  });

  test('dev tokens are accepted only when configured', () async {
    final v = AppCheckVerifier(
        projectNumber: issuer.projectNumber,
        jwks: StaticJwksSource(issuer.jwks()));
    final handler = const Pipeline()
        .addMiddleware(appCheckMiddleware(v, devTokens: ['local-dev-token-1']))
        .addHandler((Request r) => Response.ok(
            (r.context[appCheckContextKey] as AppCheckClaims).appId));
    final ok = await handler(Request('POST', Uri.parse('http://x/a'),
        headers: {'x-firebase-appcheck': 'local-dev-token-1'}));
    expect(await ok.readAsString(), 'dev-token');
    final bad = await handler(Request('POST', Uri.parse('http://x/a'),
        headers: {'x-firebase-appcheck': 'local-dev-token-2'}));
    expect(bad.statusCode, 401);
  });
}
