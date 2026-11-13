// AC-6: requests per minute with Retry-After, subject keys (ip / app),
// daily token budget from counted usage, and windows reopening on a fake clock.
import 'package:flutter_llm_proxy/flutter_llm_proxy.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  const path = '/openai/v1/chat/completions';

  group('RateLimiter (unit, fake clock)', () {
    test(
        '3 per minute: allow, allow, allow, deny with Retry-After 1..60; next window allows',
        () {
      final clock = FakeClock(DateTime.utc(2026, 11, 14, 12, 0, 10));
      final l = RateLimiter(requestsPerMinute: 3, clock: clock.call);
      expect([for (var i = 0; i < 3; i++) l.check('a').allowed],
          [true, true, true]);
      final d = l.check('a');
      expect(d.allowed, isFalse);
      expect(d.kind, LimitKind.requestsPerMinute);
      expect(d.retryAfterSeconds, 50,
          reason: '12:00:10 -> window ends 12:01:00');
      expect(l.check('b').allowed, isTrue,
          reason: 'other subjects are counted separately');
      clock.advance(const Duration(seconds: 50));
      expect(l.check('a').allowed, isTrue);
    });

    test('Retry-After is always a whole number from 1 to 60', () {
      final clock = FakeClock(DateTime.utc(2026, 11, 14, 12, 0, 59, 999));
      final l = RateLimiter(requestsPerMinute: 1, clock: clock.call);
      l.check('a');
      expect(l.check('a').retryAfterSeconds, 1);
      clock.advance(const Duration(milliseconds: 1)); // 12:01:00.000
      l.check('a');
      expect(l.check('a').retryAfterSeconds, 60);
    });

    test(
        'tokens per day: once the budget is used up the next request is refused until UTC midnight',
        () {
      final clock = FakeClock(DateTime.utc(2026, 11, 14, 23, 0, 0));
      final l = RateLimiter(tokensPerDay: 100, clock: clock.call);
      expect(l.check('a').allowed, isTrue);
      l.addTokens('a', 60);
      expect(l.check('a').allowed, isTrue, reason: '60 < 100');
      l.addTokens('a', 60);
      final d = l.check('a');
      expect(d.allowed, isFalse);
      expect(d.kind, LimitKind.tokensPerDay);
      expect(d.retryAfterSeconds, 3600);
      clock.advance(const Duration(hours: 1));
      expect(l.check('a').allowed, isTrue, reason: 'new UTC day');
    });

    test('global token budget covers all subjects together', () {
      final l = RateLimiter(globalTokensPerDay: 50);
      l.addTokens('a', 30);
      l.addTokens('b', 30);
      final d = l.check('c');
      expect(d.allowed, isFalse);
      expect(d.kind, LimitKind.globalTokensPerDay);
    });
  });

  group('over HTTP', () {
    test('same subject: 200, 200, 200, 429 with integer Retry-After', () async {
      final p = await TestProxy.start(
          limits: const LimitsConfig(
              subject: SubjectKey.appAndIp, requestsPerMinute: 3));
      try {
        final codes = <int>[];
        String? retryAfter;
        Map<String, Object?>? err;
        for (var i = 0; i < 4; i++) {
          final r =
              await p.post(path, body: chatBody(), token: p.issuer.token());
          codes.add(r.statusCode);
          if (r.statusCode == 429) {
            retryAfter = r.headers['retry-after'];
            err = p.errorOf(r);
          }
        }
        expect(codes, [200, 200, 200, 429]);
        final seconds = int.parse(retryAfter!);
        expect(seconds, inInclusiveRange(1, 60));
        expect(err, {
          'type': 'proxy_error',
          'code': 'rate_limited',
          'reason': 'requests_per_minute'
        });
        expect(p.mock.requests.length, 3,
            reason: 'the refused request never reached the upstream');
      } finally {
        await p.close();
      }
    });

    test('subject ip: different client IPs are counted separately', () async {
      final p = await TestProxy.start(
          trustForwardedFor: true,
          limits:
              const LimitsConfig(subject: SubjectKey.ip, requestsPerMinute: 2));
      try {
        Future<int> from(String ip) async => (await p.post(path,
                body: chatBody(),
                token: p.issuer.token(),
                headers: {'x-forwarded-for': ip}))
            .statusCode;
        expect([
          await from('10.0.0.1'),
          await from('10.0.0.1'),
          await from('10.0.0.1')
        ], [
          200,
          200,
          429
        ]);
        expect(await from('10.0.0.2'), 200);
      } finally {
        await p.close();
      }
    });

    test('subject app: the same app ID from different IPs shares one counter',
        () async {
      final p = await TestProxy.start(
          trustForwardedFor: true,
          limits: const LimitsConfig(
              subject: SubjectKey.app, requestsPerMinute: 2));
      try {
        Future<int> from(String ip) async => (await p.post(path,
                body: chatBody(),
                token: p.issuer.token(),
                headers: {'x-forwarded-for': ip}))
            .statusCode;
        expect([
          await from('10.0.0.1'),
          await from('10.0.0.2'),
          await from('10.0.0.3')
        ], [
          200,
          200,
          429
        ]);
      } finally {
        await p.close();
      }
    });

    test('X-Forwarded-For is ignored unless trust_forwarded_for is on',
        () async {
      final p = await TestProxy.start(
          limits:
              const LimitsConfig(subject: SubjectKey.ip, requestsPerMinute: 1));
      try {
        Future<int> from(String ip) async => (await p.post(path,
                body: chatBody(),
                token: p.issuer.token(),
                headers: {'x-forwarded-for': ip}))
            .statusCode;
        expect([await from('10.0.0.1'), await from('10.0.0.2')], [200, 429],
            reason: 'both are 127.0.0.1');
      } finally {
        await p.close();
      }
    });

    test(
        'daily token budget: counted usage (13 per reply) makes the next request 429',
        () async {
      final p = await TestProxy.start(
          limits:
              const LimitsConfig(subject: SubjectKey.app, tokensPerDay: 20));
      try {
        final r1 =
            await p.post(path, body: chatBody(), token: p.issuer.token()); // 13
        final r2 = await p.post(path,
            body: chatBody(), token: p.issuer.token()); // 26 >= 20
        final r3 =
            await p.post(path, body: chatBody(), token: p.issuer.token());
        expect([r1.statusCode, r2.statusCode, r3.statusCode], [200, 200, 429]);
        expect(p.errorOf(r3)['reason'], 'tokens_per_day');
        expect(int.parse(r3.headers['retry-after']!), greaterThanOrEqualTo(1));
        expect(p.app.limiter.tokensUsed(p.issuer.appId), 26);
      } finally {
        await p.close();
      }
    });

    test('after the window passes (fake clock) requests succeed again',
        () async {
      final clock = FakeClock(DateTime.utc(2026, 11, 14, 12, 0, 30));
      final p = await TestProxy.start(
          clock: clock.call,
          limits: const LimitsConfig(
              subject: SubjectKey.app, requestsPerMinute: 1));
      try {
        // 발급기는 실제 시계, 프록시는 가짜 시계 — 토큰은 넉넉히 길게.
        String t() => p.issuer.token(expiresIn: const Duration(days: 3650));
        expect(
            (await p.post(path, body: chatBody(), token: t())).statusCode, 200);
        final refused = await p.post(path, body: chatBody(), token: t());
        expect(refused.statusCode, 429);
        expect(refused.headers['retry-after'], '30');
        clock.advance(const Duration(seconds: 30));
        expect(
            (await p.post(path, body: chatBody(), token: t())).statusCode, 200);
      } finally {
        await p.close();
      }
    });
  });
}
