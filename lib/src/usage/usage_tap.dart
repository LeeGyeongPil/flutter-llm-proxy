import 'dart:convert';

import '../config.dart';

/// Token usage reported by the provider.
class Usage {
  const Usage(
      {this.inputTokens = 0, this.outputTokens = 0, required this.totalTokens});
  final int inputTokens;
  final int outputTokens;
  final int totalTokens;

  static const zero = Usage(totalTokens: 0);

  @override
  String toString() =>
      'Usage(in: $inputTokens, out: $outputTokens, total: $totalTokens)';
}

/// What the tap found after the response ended.
class UsageResult {
  const UsageResult(this.usage, {required this.missing});

  /// Zero tokens when [missing].
  final Usage usage;

  /// True when the response carried no usage at all (OpenAI without
  /// `include_usage`, a stream cut short, an error body). Only the
  /// request-per-minute limit applies to such requests.
  final bool missing;
}

/// Watches response bytes go by and pulls out token usage.
///
/// It never changes the bytes: the caller forwards each chunk unchanged and
/// also hands it to [add]. SSE (`text/event-stream`) is parsed event by
/// event; anything else is treated as a JSON body and parsed at [finish].
///
/// The rules per provider (the reason this class exists):
/// - OpenAI: the last chunk has `choices: []` and `usage` (only when
///   `stream_options.include_usage` is true). Other chunks have `usage: null`.
/// - Anthropic: `message_start.message.usage.input_tokens`, then
///   `message_delta.usage.output_tokens`, which is CUMULATIVE — take the last
///   value, never add them up.
/// - Gemini: every chunk carries `usageMetadata` with running totals — the
///   last one wins.
class UsageTap {
  UsageTap(this.provider,
      {required this.isEventStream, this.maxJsonBytes = 4 * 1024 * 1024});

  final ProviderType provider;
  final bool isEventStream;

  /// Non-SSE bodies are kept in memory to parse at the end — up to this size.
  final int maxJsonBytes;

  // 청크 경계에서 UTF-8 글자가 잘려도 안전하게 이어 붙이는 디코더.
  late final _decoder = const Utf8Decoder(allowMalformed: true)
      .startChunkedConversion(_LineSink(_onText));
  final _jsonBytes = <int>[];
  var _jsonTooBig = false;

  String _pending = '';
  final _dataLines = <String>[];

  int? _input;
  int? _output;
  int? _total;
  var _found = false;

  /// Number of SSE events seen (for logs and the demo).
  int events = 0;

  void add(List<int> chunk) {
    if (isEventStream) {
      _decoder.add(chunk);
    } else if (!_jsonTooBig) {
      if (_jsonBytes.length + chunk.length > maxJsonBytes) {
        _jsonTooBig = true;
        _jsonBytes.clear();
      } else {
        _jsonBytes.addAll(chunk);
      }
    }
  }

  UsageResult finish() {
    if (isEventStream) {
      _decoder.close();
      _onLine(_pending);
      _pending = '';
      _dispatch();
    } else if (!_jsonTooBig && _jsonBytes.isNotEmpty) {
      try {
        _onJson(jsonDecode(utf8.decode(_jsonBytes, allowMalformed: true)));
      } catch (_) {
        // JSON 이 아니면 usage 없음으로 처리
      }
    }
    if (!_found) return const UsageResult(Usage.zero, missing: true);
    final input = _input ?? 0;
    final output = _output ?? 0;
    return UsageResult(
      Usage(
          inputTokens: input,
          outputTokens: output,
          totalTokens: _total ?? input + output),
      missing: false,
    );
  }

  // ---- SSE 줄 단위 처리 ----
  void _onText(String text) {
    final s = _pending + text;
    final lines = s.split('\n');
    _pending = lines.removeLast(); // 아직 끝나지 않은 줄
    for (final line in lines) {
      _onLine(line);
    }
    // 줄바꿈 없이 끝없이 오는 비정상 스트림에 메모리가 늘지 않도록 상한을 둔다.
    if (_pending.length > maxJsonBytes) _pending = '';
    if (_dataLines.length > 10000) _dataLines.clear();
  }

  void _onLine(String raw) {
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    if (line.isEmpty) {
      _dispatch(); // 빈 줄 = 이벤트 끝
    } else if (line.startsWith('data:')) {
      final v = line.substring(5);
      _dataLines.add(v.startsWith(' ') ? v.substring(1) : v);
    }
    // event:, id:, retry:, 주석(:) 줄은 usage 와 무관하다.
  }

  void _dispatch() {
    if (_dataLines.isEmpty) return;
    final data = _dataLines.join('\n');
    _dataLines.clear();
    events++;
    if (data == '[DONE]') return;
    try {
      _onJson(jsonDecode(data));
    } catch (_) {
      // JSON 이 아닌 data 는 건너뛴다.
    }
  }

  // ---- 제공자별 usage 추출 ----
  void _onJson(Object? json) {
    if (json is List) {
      // Gemini 비스트림 streamGenerateContent 는 JSON 배열로 온다.
      for (final item in json) {
        _onJson(item);
      }
      return;
    }
    if (json is! Map) return;
    switch (provider) {
      case ProviderType.openai:
        final u = json['usage'];
        if (u is Map) {
          _found = true;
          _input = _int(u['prompt_tokens']) ?? _input;
          _output = _int(u['completion_tokens']) ?? _output;
          _total = _int(u['total_tokens']) ?? _total;
        }
      case ProviderType.anthropic:
        // 스트림: message_start 안의 message.usage / 비스트림: 최상위 usage
        final type = json['type'];
        final message = json['message'];
        final u = type == 'message_start'
            ? (message is Map ? message['usage'] : null)
            : json['usage'];
        if (u is Map) {
          _found = true;
          // 누적값이므로 "더하기"가 아니라 "마지막 값으로 바꾸기".
          _input = _int(u['input_tokens']) ?? _input;
          _output = _int(u['output_tokens']) ?? _output;
          _total = null; // 입력+출력으로 계산
        }
      case ProviderType.gemini:
        final u = json['usageMetadata'];
        if (u is Map) {
          _found = true;
          _input = _int(u['promptTokenCount']) ?? _input;
          _output = _int(u['candidatesTokenCount']) ?? _output;
          _total = _int(u['totalTokenCount']) ?? _total;
        }
    }
  }

  static int? _int(Object? v) => v is num ? v.toInt() : null;
}

class _LineSink implements Sink<String> {
  _LineSink(this._onText);
  final void Function(String) _onText;
  @override
  void add(String data) => _onText(data);
  @override
  void close() {}
}
