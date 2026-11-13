import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';
import 'package:shelf/shelf.dart';

import 'clock.dart';
import 'i18n/messages.dart';
import 'proxy/errors.dart';
import 'proxy/stream_watch.dart';
import 'usage/usage_tap.dart';

/// Filled in by the middlewares and the forwarder while a request runs,
/// then written as one log line when the response ends.
class RequestStats {
  String? subject;
  String? provider;
  UsageResult? usage;
  String? reason;
  bool cancelled = false;
}

/// One line per request: time, method, path (no query string), status,
/// hashed subject, tokens, duration. Known secrets (server keys, dev tokens)
/// are replaced with `***` in every line, and request headers are never
/// logged, so App Check tokens and keys cannot leak into logs.
class RequestLogger {
  RequestLogger(
      {void Function(String line)? sink,
      this.lang = Lang.en,
      Iterable<String> secrets = const [],
      Clock? clock})
      : _sink = sink ?? print,
        _clock = clock ?? systemClock {
    secrets.forEach(addSecret);
  }

  final void Function(String line) _sink;
  final Lang lang;
  final Clock _clock;
  final _secrets = <String>{};

  void addSecret(String secret) {
    // 너무 짧은 값은 가리면 오히려 로그를 망가뜨리므로 4자 이상만.
    if (secret.length >= 4) _secrets.add(secret);
  }

  String redact(String text) {
    var out = text;
    for (final s in _secrets) {
      out = out.replaceAll(s, '***');
    }
    return out;
  }

  /// A translated free-form line (startup banner, warnings).
  void info(String messageKey, [Map<String, Object?> args = const {}]) {
    _sink(redact(Messages(lang).t(messageKey, args)));
  }

  /// Short, non-reversible label for a subject (app ID / IP) in logs.
  static String hashSubject(String subject) {
    final digest =
        SHA256Digest().process(Uint8List.fromList(utf8.encode(subject)));
    return digest
        .take(4)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Middleware middleware() {
    return (Handler inner) {
      return (Request request) async {
        final stats = RequestStats();
        final started = Stopwatch()..start();
        final req = request.change(context: {statsContextKey: stats});
        Response response;
        try {
          response = await inner(req);
        } catch (e) {
          stats.reason = 'internal_error';
          response = proxyError(500, 'internal_error');
        }
        final status = response.statusCode;
        // 스트리밍 응답은 끝(또는 끊김)까지 기다렸다가 토큰 수와 함께 한 줄을 남긴다.
        final body = watchStream(response.read(), onFinish: (cancelled) {
          stats.cancelled = cancelled;
          _writeLine(request, status, stats, started.elapsedMilliseconds);
        });
        return response.change(body: body);
      };
    };
  }

  void _writeLine(Request request, int status, RequestStats stats, int ms) {
    final m = Messages(lang);
    final notes = <String>[];
    if (stats.reason != null) notes.add('reason=${stats.reason}');
    if (stats.usage?.missing == true) notes.add(m.t('log.usage_missing'));
    if (stats.cancelled) notes.add(m.t('log.client_disconnected'));
    final line = m.t('log.request', {
      'time': _clock().toIso8601String(),
      'method': request.method,
      'path': '/${request.url.path}', // 쿼리 문자열(키가 들어 있을 수 있음)은 남기지 않는다
      'status': status,
      'subject': stats.subject == null ? '-' : hashSubject(stats.subject!),
      'tokens': stats.usage == null || stats.usage!.missing
          ? '-'
          : stats.usage!.usage.totalTokens,
      'ms': ms,
      'notes': notes.isEmpty ? '' : ' ${notes.join(' ')}',
    });
    _sink(redact(line));
  }
}
