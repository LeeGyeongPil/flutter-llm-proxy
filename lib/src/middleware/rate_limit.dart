import 'dart:io';

import 'package:shelf/shelf.dart';

import '../app_check/verifier.dart';
import '../clock.dart';
import '../config.dart';
import '../log.dart';
import '../proxy/errors.dart';

/// Which limit refused the request (the `reason` in the 429 body).
enum LimitKind {
  requestsPerMinute('requests_per_minute'),
  tokensPerDay('tokens_per_day'),
  globalTokensPerDay('global_tokens_per_day');

  const LimitKind(this.code);
  final String code;
}

class LimitDecision {
  const LimitDecision.allowed()
      : allowed = true,
        kind = null,
        retryAfterSeconds = 0;
  const LimitDecision.denied(LimitKind this.kind, this.retryAfterSeconds)
      : allowed = false;

  final bool allowed;
  final LimitKind? kind;

  /// Whole seconds until the refused limit resets (the `Retry-After` value).
  final int retryAfterSeconds;
}

/// In-memory limits, per server instance.
///
/// - Requests per minute: fixed one-minute windows (`12:00:00–12:00:59`).
/// - Tokens per day (per subject and global): counted after each response
///   from the usage the provider reported; once a budget is used up, the
///   NEXT request gets 429 until UTC midnight. (A single request can go over
///   the budget — the proxy cannot know the cost before the reply.)
///
/// Memory stays bounded: counters for a past minute or day are dropped as
/// soon as the window changes.
class RateLimiter {
  RateLimiter(
      {this.requestsPerMinute,
      this.tokensPerDay,
      this.globalTokensPerDay,
      Clock? clock})
      : _clock = clock ?? systemClock;

  final int? requestsPerMinute;
  final int? tokensPerDay;
  final int? globalTokensPerDay;
  final Clock _clock;

  int _minuteId = -1;
  final _requests = <String, int>{};
  int _dayId = -1;
  final _tokens = <String, int>{};
  int _globalTokens = 0;

  static const _minuteMs = 60 * 1000;
  static const _dayMs = 24 * 60 * 60 * 1000;

  void _roll(int nowMs) {
    // 창이 바뀌면 지난 창의 기록을 통째로 버린다(상한 없는 메모리 증가 방지).
    final minute = nowMs ~/ _minuteMs;
    if (minute != _minuteId) {
      _minuteId = minute;
      _requests.clear();
    }
    final day = nowMs ~/ _dayMs;
    if (day != _dayId) {
      _dayId = day;
      _tokens.clear();
      _globalTokens = 0;
    }
  }

  static int _secondsUntil(int nowMs, int periodMs) {
    final left = periodMs - (nowMs % periodMs);
    final s = (left + 999) ~/ 1000; // 올림
    return s < 1 ? 1 : s;
  }

  /// Counts one request for [subject] if every limit allows it.
  LimitDecision check(String subject) {
    final nowMs = _clock().millisecondsSinceEpoch;
    _roll(nowMs);
    if (globalTokensPerDay != null && _globalTokens >= globalTokensPerDay!) {
      return LimitDecision.denied(
          LimitKind.globalTokensPerDay, _secondsUntil(nowMs, _dayMs));
    }
    if (tokensPerDay != null && (_tokens[subject] ?? 0) >= tokensPerDay!) {
      return LimitDecision.denied(
          LimitKind.tokensPerDay, _secondsUntil(nowMs, _dayMs));
    }
    if (requestsPerMinute != null) {
      final used = _requests[subject] ?? 0;
      if (used >= requestsPerMinute!) {
        return LimitDecision.denied(
            LimitKind.requestsPerMinute, _secondsUntil(nowMs, _minuteMs));
      }
      _requests[subject] = used + 1;
    }
    return const LimitDecision.allowed();
  }

  /// Adds tokens a finished response used.
  void addTokens(String subject, int tokens) {
    if (tokens <= 0) return;
    _roll(_clock().millisecondsSinceEpoch);
    if (tokensPerDay != null)
      _tokens[subject] = (_tokens[subject] ?? 0) + tokens;
    _globalTokens += tokens;
  }

  /// Tokens [subject] used today (for tests and the demo).
  int tokensUsed(String subject) => _tokens[subject] ?? 0;
}

/// The string limits are counted per.
String subjectFor(Request request, SubjectKey key,
    {bool trustForwardedFor = false}) {
  final claims = request.context[appCheckContextKey] as AppCheckClaims?;
  final app = claims?.appId ?? 'no-app-check';
  String ip = 'unknown';
  final forwarded = request.headers['x-forwarded-for'];
  if (trustForwardedFor && forwarded != null && forwarded.trim().isNotEmpty) {
    // 신뢰하는 리버스 프록시가 붙인 값의 첫 주소 = 실제 클라이언트
    ip = forwarded.split(',').first.trim();
  } else {
    final info = request.context['shelf.io.connection_info'];
    if (info is HttpConnectionInfo) ip = info.remoteAddress.address;
  }
  return switch (key) {
    SubjectKey.app => app,
    SubjectKey.ip => ip,
    SubjectKey.appAndIp => '$app|$ip',
  };
}

/// 429 with `Retry-After` when [limiter] refuses; otherwise passes the
/// request on with its subject in `request.context['flutter_llm_proxy.subject']`.
Middleware rateLimitMiddleware(RateLimiter limiter, SubjectKey subject,
    {bool trustForwardedFor = false}) {
  return (Handler inner) {
    return (Request request) {
      final who =
          subjectFor(request, subject, trustForwardedFor: trustForwardedFor);
      final stats = request.context[statsContextKey] as RequestStats?;
      stats?.subject = who;
      final decision = limiter.check(who);
      if (!decision.allowed) {
        stats?.reason = decision.kind!.code;
        return proxyError(429, 'rate_limited',
            reason: decision.kind!.code,
            headers: {'retry-after': '${decision.retryAfterSeconds}'});
      }
      return inner(request.change(context: {subjectContextKey: who}));
    };
  };
}
