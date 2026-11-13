// AC-5: usage parsing on the golden fixtures (incl. the Anthropic
// cumulative-usage trap), byte-for-byte pass-through, include_usage
// injection, and "usage missing" when the provider sends none.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_llm_proxy/flutter_llm_proxy.dart';
import 'package:flutter_llm_proxy/src/mock/fixtures.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/harness.dart';

/// Feeds [text] to a tap in [size]-byte pieces (cuts through UTF-8 and lines).
UsageResult tapInPieces(ProviderType p, String text,
    {int size = 7, bool sse = true}) {
  final tap = UsageTap(p, isEventStream: sse);
  final bytes = utf8.encode(text);
  for (var i = 0; i < bytes.length; i += size) {
    tap.add(
        bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size));
  }
  return tap.finish();
}

/// What a naive "add every usage number you see" counter would report.
int naiveSum(String sse, List<String> fields) {
  var sum = 0;
  for (final f in fields) {
    for (final m in RegExp('"$f":(\\d+)').allMatches(sse)) {
      sum += int.parse(m.group(1)!);
    }
  }
  return sum;
}

void main() {
  group('golden fixtures', () {
    test('fixtures/sse/*.sse match the copies embedded for the executable', () {
      expect(File('fixtures/sse/openai_chat.sse').readAsStringSync(),
          openaiChatSse);
      expect(File('fixtures/sse/anthropic_messages.sse').readAsStringSync(),
          anthropicMessagesSse);
      expect(File('fixtures/sse/gemini_stream.sse').readAsStringSync(),
          geminiStreamSse);
    });

    test('OpenAI: the final usage chunk (choices: []) gives total 13', () {
      for (final size in [1, 7, 64, 100000]) {
        final r = tapInPieces(ProviderType.openai, openaiChatSse, size: size);
        expect(r.missing, isFalse);
        expect(r.usage.inputTokens, 9);
        expect(r.usage.outputTokens, 4);
        expect(r.usage.totalTokens, 13, reason: 'chunk size $size');
      }
    });

    test('Anthropic: output_tokens is cumulative - last value, never the sum',
        () {
      final r = tapInPieces(ProviderType.anthropic, anthropicMessagesSse);
      expect(r.usage.inputTokens, 25);
      expect(r.usage.outputTokens, 15);
      expect(r.usage.totalTokens, 40);
      // 함정: message_start 의 output_tokens(1) 와 message_delta(15) 를 더하면 41 이 된다.
      final naive =
          naiveSum(anthropicMessagesSse, ['input_tokens', 'output_tokens']);
      expect(naive, 41);
      expect(r.usage.totalTokens, lessThan(naive));
    });

    test('Gemini: last usageMetadata.totalTokenCount (13), not the running sum',
        () {
      final r = tapInPieces(ProviderType.gemini, geminiStreamSse);
      expect(r.usage.totalTokens, 13);
      expect(r.usage.inputTokens, 8);
      expect(r.usage.outputTokens, 5);
      expect(naiveSum(geminiStreamSse, ['totalTokenCount']), 33);
    });

    test('CRLF line endings and multi-byte text split across chunks', () {
      final sse =
          'data: {"choices":[{"delta":{"content":"안녕하세요"}}],"usage":null}\r\n\r\n'
          'data: {"choices":[],"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5}}\r\n\r\n'
          'data: [DONE]\r\n\r\n';
      final r = tapInPieces(ProviderType.openai, sse, size: 1);
      expect(r.usage.totalTokens, 5);
    });

    test('non-stream JSON bodies (incl. Gemini JSON array)', () {
      expect(
          tapInPieces(ProviderType.openai,
                  '{"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}',
                  sse: false)
              .usage
              .totalTokens,
          3);
      expect(
          tapInPieces(ProviderType.anthropic,
                  '{"type":"message","usage":{"input_tokens":4,"output_tokens":6}}',
                  sse: false)
              .usage
              .totalTokens,
          10);
      expect(
          tapInPieces(ProviderType.gemini,
                  '[{"usageMetadata":{"totalTokenCount":5}},{"usageMetadata":{"promptTokenCount":3,"candidatesTokenCount":4,"totalTokenCount":7}}]',
                  sse: false)
              .usage
              .totalTokens,
          7);
    });

    test('no usage anywhere -> 0 tokens, missing = true', () {
      final r = tapInPieces(ProviderType.openai,
          'data: {"choices":[{"delta":{"content":"x"}}]}\n\ndata: [DONE]\n\n');
      expect(r.missing, isTrue);
      expect(r.usage.totalTokens, 0);
    });
  });

  group('through the proxy', () {
    late TestProxy proxy;

    setUpAll(() async {
      proxy = await TestProxy.start(
        chunkDelay: const Duration(milliseconds: 5),
        limits:
            const LimitsConfig(subject: SubjectKey.app, tokensPerDay: 1000000),
      );
    });
    tearDownAll(() => proxy.close());

    Future<List<int>> rawStream(String path, Object body) async {
      final req = http.Request('POST', proxy.url(path))
        ..headers['content-type'] = 'application/json'
        ..headers['x-firebase-appcheck'] = proxy.issuer.token()
        ..body = jsonEncode(body);
      final res = await proxy.client.send(req);
      expect(res.statusCode, 200);
      return (await res.stream.toList()).expand((c) => c).toList();
    }

    test(
        'bytes the app receives are identical to the upstream bytes (3 providers)',
        () async {
      expect(
          utf8.decode(await rawStream(
              '/openai/v1/chat/completions', chatBody(stream: true))),
          openaiChatSse);
      expect(
          utf8.decode(await rawStream('/anthropic/v1/messages',
              {'model': 'claude-mock', 'stream': true})),
          anthropicMessagesSse);
      expect(
          utf8.decode(await rawStream(
              '/gemini/v1beta/models/gemini-mock:streamGenerateContent?alt=sse',
              {})),
          geminiStreamSse);
    });

    test(
        'inject_include_usage adds stream_options.include_usage=true (keeping other options)',
        () async {
      await rawStream('/openai/v1/chat/completions',
          chatBody(stream: true, streamOptions: {'other': 1}));
      final sent =
          jsonDecode(proxy.mock.requests.last.body) as Map<String, dynamic>;
      expect(sent['stream_options'], {'other': 1, 'include_usage': true});
    });

    test('counted usage goes into the daily token budget', () async {
      final before = proxy.app.limiter.tokensUsed(proxy.issuer.appId);
      await rawStream(
          '/anthropic/v1/messages', {'model': 'claude-mock', 'stream': true});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(proxy.app.limiter.tokensUsed(proxy.issuer.appId) - before, 40);
      expect(proxy.logs.last, contains('tokens=40'));
    });
  });

  test(
      'without include_usage injection OpenAI sends no usage: 0 tokens, log says "usage missing"',
      () async {
    final p = await TestProxy.start(
      chunkDelay: const Duration(milliseconds: 5),
      injectIncludeUsage: false,
      limits:
          const LimitsConfig(subject: SubjectKey.app, tokensPerDay: 1000000),
    );
    try {
      final req = http.Request('POST', p.url('/openai/v1/chat/completions'))
        ..headers['content-type'] = 'application/json'
        ..headers['x-firebase-appcheck'] = p.issuer.token()
        ..body = jsonEncode(chatBody(stream: true));
      final body = await (await p.client.send(req)).stream.bytesToString();
      expect(body, isNot(contains('"usage":{')));
      final sent =
          jsonDecode(p.mock.requests.last.body) as Map<String, dynamic>;
      expect(sent.containsKey('stream_options'), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(p.app.limiter.tokensUsed(p.issuer.appId), 0);
      expect(p.logs.last, contains('(usage missing)'));
      expect(p.logs.last, contains('tokens=-'));
    } finally {
      await p.close();
    }
  });
}
