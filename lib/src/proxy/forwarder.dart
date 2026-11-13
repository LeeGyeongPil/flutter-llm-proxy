import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';

import '../config.dart';
import '../log.dart';
import '../usage/usage_tap.dart';
import 'errors.dart';
import 'stream_watch.dart';

/// Makes the HTTP client for ONE upstream request. A fresh client per
/// request lets the proxy cancel exactly that upstream call (by closing the
/// client) when the app disconnects mid-stream.
typedef UpstreamClientFactory = http.Client Function();

/// Called once per proxied response with the usage found in it.
typedef UsageSink = void Function(
    Request request, ProviderConfig provider, UsageResult usage);

/// Client headers that never go upstream: the app's own credentials
/// (the server key replaces them), cookies, hop-by-hop headers, and
/// `accept-encoding` (the proxy must read plain bytes to count usage).
const _dropRequestHeaders = {
  'authorization',
  'x-api-key',
  'x-goog-api-key',
  'x-firebase-appcheck',
  'cookie',
  'host',
  'connection',
  'keep-alive',
  'proxy-authorization',
  'proxy-connection',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
  'content-length',
  'accept-encoding',
  'origin',
  'referer',
  'forwarded',
  'x-forwarded-for',
  'x-forwarded-host',
  'x-forwarded-proto',
};

/// Upstream headers that are not passed back (shelf sets framing itself;
/// bodies arrive already decompressed).
const _dropResponseHeaders = {
  'connection',
  'keep-alive',
  'transfer-encoding',
  'content-length',
  'content-encoding',
  'set-cookie',
  'alt-svc',
};

class Forwarder {
  Forwarder(
    this.provider, {
    required this.serverKey,
    required this.maxBodyBytes,
    UpstreamClientFactory? clientFactory,
    this.onUsage,
    this.bufferOutput = false,
  }) : _clientFactory = clientFactory ?? http.Client.new;

  final ProviderConfig provider;
  final String serverKey;
  final int maxBodyBytes;
  final UpstreamClientFactory _clientFactory;
  final UsageSink? onUsage;

  /// Keep `false`. `true` reproduces shelf's default (buffer the whole
  /// response before sending) — only used to demonstrate the pitfall.
  final bool bufferOutput;

  /// Forwards [request] to `upstream + upstreamPath`.
  Future<Response> forward(Request request, String upstreamPath) async {
    final stats = request.context[statsContextKey] as RequestStats?;
    stats?.provider = provider.id;

    // 1) 본문 크기 상한 — 선언 크기가 크면 읽기 전에, 아니면 읽으면서 센다.
    final declared = request.contentLength;
    if (declared != null && declared > maxBodyBytes)
      return _reject(stats, 413, 'body_too_large');
    final bytes = <int>[];
    await for (final chunk in request.read()) {
      bytes.addAll(chunk);
      if (bytes.length > maxBodyBytes)
        return _reject(stats, 413, 'body_too_large');
    }

    // 2) 모델 허용 목록 + OpenAI include_usage 주입
    var body = bytes;
    if (provider.type == ProviderType.gemini) {
      final m = RegExp(r'/models/([^/:]+)').firstMatch(upstreamPath);
      final model = m?.group(1);
      if (provider.allowedModels.isNotEmpty &&
          (model == null || !provider.allowedModels.contains(model))) {
        return _reject(stats, 403, 'model_not_allowed');
      }
    } else if (bytes.isNotEmpty) {
      Map<String, dynamic> json;
      try {
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is! Map<String, dynamic>)
          return _reject(stats, 400, 'invalid_json');
        json = decoded;
      } catch (_) {
        return _reject(stats, 400, 'invalid_json');
      }
      final model = json['model'];
      if (provider.allowedModels.isNotEmpty &&
          (model is! String || !provider.allowedModels.contains(model))) {
        return _reject(stats, 403, 'model_not_allowed');
      }
      if (provider.type == ProviderType.openai &&
          provider.injectIncludeUsage &&
          json['stream'] == true) {
        // 이게 없으면 OpenAI 스트림에는 usage 가 아예 오지 않아 토큰 한도를 셀 수 없다.
        final options = Map<String, dynamic>.from(
            (json['stream_options'] as Map?) ?? const {});
        options['include_usage'] = true;
        json['stream_options'] = options;
        body = utf8.encode(jsonEncode(json));
      }
    } else if (provider.allowedModels.isNotEmpty && request.method == 'POST') {
      return _reject(stats, 400, 'invalid_json');
    }

    // 3) 업스트림 요청 — 클라이언트 자격 증명은 지우고 서버 키를 붙인다.
    final url = _upstreamUrl(request, upstreamPath);
    final upstream = http.Request(request.method, url);
    request.headers.forEach((name, value) {
      if (!_dropRequestHeaders.contains(name.toLowerCase()))
        upstream.headers[name] = value;
    });
    switch (provider.keyHeader) {
      case KeyHeaderStyle.bearer:
        upstream.headers['authorization'] = 'Bearer $serverKey';
      case KeyHeaderStyle.xApiKey:
        upstream.headers['x-api-key'] = serverKey;
      case KeyHeaderStyle.xGoogApiKey:
        upstream.headers['x-goog-api-key'] = serverKey;
    }
    if (body.isNotEmpty) upstream.bodyBytes = body;

    final client = _clientFactory();
    http.StreamedResponse res;
    try {
      // 실제 모델은 첫 바이트까지 오래 걸릴 수 있어 넉넉히 기다린다.
      res = await client.send(upstream).timeout(const Duration(minutes: 5));
    } catch (_) {
      client.close();
      return _reject(stats, 502, 'upstream_unreachable');
    }

    // 4) 응답 — 바이트는 그대로 흘리고 usage 만 엿본다.
    final contentType = res.headers['content-type'] ?? '';
    final isEventStream =
        contentType.toLowerCase().startsWith('text/event-stream');
    final headers = <String, String>{};
    res.headers.forEach((name, value) {
      if (!_dropResponseHeaders.contains(name.toLowerCase()))
        headers[name] = value;
    });
    if (isEventStream) {
      headers['cache-control'] = 'no-cache';
      headers['x-accel-buffering'] = 'no'; // nginx 등 앞단 프록시도 버퍼링하지 말라는 신호
    }

    final tap = UsageTap(provider.type, isEventStream: isEventStream);
    final passthrough = watchStream(
      res.stream,
      onChunk: tap.add,
      onFinish: (cancelled) {
        // 끝났든 끊겼든 요청별 클라이언트를 닫는다 — 끊긴 경우 업스트림 요청도 여기서 취소된다.
        client.close();
        final usage = tap.finish();
        stats?.usage = usage;
        onUsage?.call(request, provider, usage);
      },
    );

    return Response(
      res.statusCode,
      body: passthrough,
      headers: headers,
      // 핵심 한 줄: shelf 기본값(true)은 응답을 모아서 보내 SSE 가 한꺼번에 도착한다.
      context: {'shelf.io.buffer_output': bufferOutput},
    );
  }

  Uri _upstreamUrl(Request request, String upstreamPath) {
    final base = provider.upstream.path.endsWith('/')
        ? provider.upstream.path.substring(0, provider.upstream.path.length - 1)
        : provider.upstream.path;
    // 클라이언트가 쿼리로 보낸 키(?key=…)는 버린다 — 키는 서버만 붙인다.
    final query = Map.of(request.url.queryParametersAll)..remove('key');
    return provider.upstream.replace(
      path: '$base$upstreamPath',
      queryParameters: query.isEmpty ? null : query,
    );
  }

  static Response _reject(RequestStats? stats, int status, String code) {
    stats?.reason = code;
    return proxyError(status, code);
  }
}
