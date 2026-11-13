// AC-4: SSE goes through without buffering, with the right headers, and a
// client that disconnects cancels the upstream request.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_llm_proxy/flutter_llm_proxy.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/harness.dart';

/// Four SSE events (OpenAI shape), sent 250 ms apart by the mock.
const fourChunks =
    'data: {"choices":[{"index":0,"delta":{"content":"one"}}],"usage":null}\n\n'
    'data: {"choices":[{"index":0,"delta":{"content":" two"}}],"usage":null}\n\n'
    'data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}\n\n'
    'data: [DONE]\n\n';

class Timing {
  Timing(this.status, this.headers, this.firstMs, this.totalMs);
  final int status;
  final Map<String, String> headers;
  final int firstMs;
  final int totalMs;
  double get ratio => firstMs / totalMs;
}

Future<Timing> timeStream(TestProxy p) async {
  final request = http.Request('POST', p.url('/openai/v1/chat/completions'))
    ..headers['content-type'] = 'application/json'
    ..headers['x-firebase-appcheck'] = p.issuer.token()
    ..body = jsonEncode(chatBody(stream: true));
  final sw = Stopwatch()..start();
  final res = await p.client.send(request);
  int? first;
  await for (final _ in res.stream) {
    first ??= sw.elapsedMilliseconds;
  }
  return Timing(res.statusCode, res.headers, first!, sw.elapsedMilliseconds);
}

void main() {
  const delay = Duration(milliseconds: 250);

  test(
      'unbuffered: first chunk arrives before 50% of the total time; SSE headers set',
      () async {
    final p = await TestProxy.start(
        chunkDelay: delay, fixtures: {ProviderType.openai: fourChunks});
    try {
      final t = await timeStream(p);
      expect(t.status, 200);
      expect(t.totalMs, greaterThanOrEqualTo(900), reason: '4 events x 250 ms');
      expect(t.ratio, lessThan(0.5),
          reason: 'first ${t.firstMs} ms of ${t.totalMs} ms');
      expect(t.headers['content-type'], startsWith('text/event-stream'));
      expect(t.headers['cache-control'], 'no-cache');
      expect(t.headers['x-accel-buffering'], 'no');
    } finally {
      await p.close();
    }
  });

  test(
      'control: shelf default buffer_output=true delivers the first chunk at 50%+ of the total',
      () async {
    final p = await TestProxy.start(
        chunkDelay: delay,
        fixtures: {ProviderType.openai: fourChunks},
        bufferOutput: true);
    try {
      final t = await timeStream(p);
      expect(t.status, 200);
      expect(t.ratio, greaterThanOrEqualTo(0.5),
          reason: 'first ${t.firstMs} ms of ${t.totalMs} ms');
    } finally {
      await p.close();
    }
  });

  test(
      'client disconnect after the first chunk cancels the upstream within 1 s',
      () async {
    final p = await TestProxy.start(
        chunkDelay: delay); // 6-event fixture, ~1.5 s in total
    final client = http.Client(); // 이 요청만을 위한 클라이언트 — 닫으면 연결이 끊긴다
    try {
      final request = http.Request('POST', p.url('/openai/v1/chat/completions'))
        ..headers['content-type'] = 'application/json'
        ..headers['x-firebase-appcheck'] = p.issuer.token()
        ..body = jsonEncode(chatBody(stream: true));
      final res = await client.send(request);
      final firstChunk = Completer<void>();
      final sub = res.stream.listen((_) {
        if (!firstChunk.isCompleted) firstChunk.complete();
      }, onError: (_) {});
      await firstChunk.future;

      final disconnectedAt = DateTime.now();
      client.close(); // 앱이 화면을 닫은 것처럼 연결을 끊는다
      unawaited(sub.cancel());

      final record = p.mock.requests.last;
      while (!record.cancelled &&
          DateTime.now().difference(disconnectedAt) <
              const Duration(seconds: 2)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(record.cancelled, isTrue, reason: 'mock upstream saw the cancel');
      expect(record.completed, isFalse);
      expect(record.cancelledAt!.difference(disconnectedAt),
          lessThan(const Duration(seconds: 1)));

      // 로그 줄은 끊김을 표시하고, 끝까지 못 받은 usage 는 없음으로 남긴다.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(p.logs.last, contains('(client disconnected)'));
    } finally {
      client.close();
      await p.close();
    }
  });
}
