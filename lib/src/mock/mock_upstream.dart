import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../config.dart';
import 'fixtures.dart';

/// One request the mock upstream received.
class MockRequestRecord {
  MockRequestRecord(this.method, this.pathAndQuery, this.headers, this.body);
  final String method;
  final String pathAndQuery;

  /// Lower-case header names.
  final Map<String, String> headers;
  final String body;

  /// The proxy (or client) went away before the stream finished.
  bool cancelled = false;
  DateTime? cancelledAt;
  bool completed = false;
}

/// PRACTICE MOCK: a local stand-in for OpenAI / Anthropic / Gemini that
/// replays recorded-format SSE samples with a delay between events.
///
/// It does not imitate a model. It exists so the proxy's real code paths
/// (attestation, limits, buffering, usage parsing, cancellation) can run
/// without keys or network. It records what it received so tests can prove
/// the server key arrived and the client's credentials did not.
class MockUpstream {
  MockUpstream._(this._server, this.chunkDelay);

  final HttpServer _server;
  final Duration chunkDelay;
  final List<MockRequestRecord> requests = [];
  Map<ProviderType, String> _fixtures = const {};

  Uri get url => Uri.parse('http://${_server.address.host}:${_server.port}');

  static Future<MockUpstream> start({
    Duration chunkDelay = const Duration(milliseconds: 250),
    Map<ProviderType, String>? fixtures,
    String host = '127.0.0.1',
    int port = 0,
  }) async {
    late MockUpstream mock;
    final server =
        await shelf_io.serve((Request r) => mock._handle(r), host, port);
    mock = MockUpstream._(server, chunkDelay)
      .._fixtures = {
        ProviderType.openai: openaiChatSse,
        ProviderType.anthropic: anthropicMessagesSse,
        ProviderType.gemini: geminiStreamSse,
        ...?fixtures,
      };
    return mock;
  }

  Future<void> close() => _server.close(force: true);

  Future<Response> _handle(Request request) async {
    final body = await request.readAsString();
    final record = MockRequestRecord(
      request.method,
      '/${request.url}',
      {for (final e in request.headers.entries) e.key.toLowerCase(): e.value},
      body,
    );
    requests.add(record);

    final path = '/${request.url.path}';
    final ProviderType provider;
    if (path.endsWith('/chat/completions')) {
      provider = ProviderType.openai;
    } else if (path.endsWith('/messages')) {
      provider = ProviderType.anthropic;
    } else if (path.contains(':streamGenerateContent') ||
        path.contains(':generateContent')) {
      provider = ProviderType.gemini;
    } else {
      return _json(404, {'error': 'mock upstream: unknown path $path'});
    }

    // 진짜 API 처럼 키 헤더가 없으면 401 — 프록시가 키를 붙였는지 드러난다.
    final hasKey = switch (provider) {
      ProviderType.openai =>
        (record.headers['authorization'] ?? '').startsWith('Bearer '),
      ProviderType.anthropic => record.headers.containsKey('x-api-key'),
      ProviderType.gemini => record.headers.containsKey('x-goog-api-key'),
    };
    if (!hasKey)
      return _json(401, {'error': 'mock upstream: missing API key header'});

    Map<String, dynamic> json = const {};
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {}

    final bool stream;
    if (provider == ProviderType.gemini) {
      stream = path.contains(':streamGenerateContent') &&
          request.url.queryParameters['alt'] == 'sse';
    } else {
      stream = json['stream'] == true;
    }

    if (!stream) {
      record.completed = true;
      return _json(200, _nonStreamBody(provider, path));
    }

    var events = _fixtures[provider]!
        .split('\n\n')
        .where((e) => e.trim().isNotEmpty)
        .toList();
    if (provider == ProviderType.openai) {
      final includeUsage =
          (json['stream_options'] as Map?)?['include_usage'] == true;
      // OpenAI 는 include_usage 를 켜야만 마지막 usage 청크를 보낸다.
      if (!includeUsage)
        events = events.where((e) => !e.contains('"choices":[]')).toList();
    }

    final controller = StreamController<List<int>>();
    controller.onCancel = () {
      record.cancelled = true;
      record.cancelledAt = DateTime.now();
    };
    controller.onListen = () async {
      for (final event in events) {
        await Future<void>.delayed(chunkDelay);
        if (record.cancelled) return;
        controller.add(utf8.encode('$event\n\n'));
      }
      record.completed = true;
      await controller.close();
    };
    return Response.ok(
      controller.stream,
      headers: {
        'content-type': 'text/event-stream',
        'cache-control': 'no-cache'
      },
      context: {'shelf.io.buffer_output': false},
    );
  }

  static Object _nonStreamBody(ProviderType provider, String path) {
    switch (provider) {
      case ProviderType.openai:
        return {
          'id': 'chatcmpl-mock2',
          'object': 'chat.completion',
          'model': 'gpt-4o-mini',
          'choices': [
            {
              'index': 0,
              'message': {
                'role': 'assistant',
                'content': 'Hello from the mock upstream.'
              },
              'finish_reason': 'stop',
            }
          ],
          'usage': {
            'prompt_tokens': 9,
            'completion_tokens': 4,
            'total_tokens': 13
          },
        };
      case ProviderType.anthropic:
        return {
          'id': 'msg_mock2',
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'Hello from the mock upstream.'}
          ],
          'stop_reason': 'end_turn',
          'usage': {'input_tokens': 25, 'output_tokens': 15},
        };
      case ProviderType.gemini:
        final one = {
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'Hello from the mock upstream.'}
                ],
                'role': 'model'
              },
              'finishReason': 'STOP',
              'index': 0,
            }
          ],
          'usageMetadata': {
            'promptTokenCount': 8,
            'candidatesTokenCount': 5,
            'totalTokenCount': 13
          },
        };
        // alt=sse 없는 streamGenerateContent 는 JSON 배열로 온다.
        return path.contains(':streamGenerateContent') ? [one] : one;
    }
  }

  static Response _json(int status, Object body) => Response(status,
      body: jsonEncode(body), headers: {'content-type': 'application/json'});
}
