import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../../testing.dart' show AppCheckTestIssuer;
import '../app_check/jwks.dart';
import '../config.dart';
import '../i18n/messages.dart';
import '../log.dart';
import '../mock/mock_upstream.dart';
import '../server.dart';

/// Result of one HTTP call made by the demo client.
class _Call {
  _Call(this.status, this.body, this.headers, this.firstChunkMs, this.totalMs);
  final int status;
  final String body;
  final Map<String, String> headers;
  final int? firstChunkMs;
  final int totalMs;

  String? get reason {
    try {
      return ((jsonDecode(body) as Map)['error'] as Map)['reason'] as String?;
    } catch (_) {
      return null;
    }
  }
}

/// `flutter_llm_proxy demo`: runs the real proxy pipeline in this process
/// against a local JWKS and the practice mock upstream, then prints what an
/// app would see. Returns true when every outcome matched the expectation.
class DemoRunner {
  DemoRunner(this.lang,
      {void Function(String line)? out,
      this.chunkDelay = const Duration(milliseconds: 250)})
      : _out = out ?? print;

  final Lang lang;
  final Duration chunkDelay;
  final void Function(String line) _out;
  Messages get _m => Messages(lang);

  var _checks = 0;
  var _failures = 0;
  final _logLines = <String>[];
  final _clientSeen = StringBuffer(); // 앱(클라이언트)이 받은 모든 바이트·헤더

  Future<bool> run({String only = 'all'}) async {
    final m = _m;
    _out(m.t('demo.banner'));
    _out('');

    // --- 준비: 자체 RSA 키로 App Check 형식 토큰을 발급하고, 그 공개키를 로컬 JWKS 로 낸다 ---
    final issuer = AppCheckTestIssuer(
      projectNumber: '123456789012',
      projectId: 'demo-project',
      appId: '1:123456789012:android:0a1b2c3d4e5f',
      kid: 'demo-key-1',
    );
    final jwksServer = await shelf_io.serve(
      (Request r) => Response.ok(jsonEncode(issuer.jwks()), headers: {
        'content-type': 'application/json',
        'cache-control': 'public, max-age=21600'
      }),
      '127.0.0.1',
      0,
    );
    final jwksUrl = Uri.parse('http://127.0.0.1:${jwksServer.port}/v1/jwks');
    final mock = await MockUpstream.start(chunkDelay: chunkDelay);
    // 데모용 가짜 서버 키 — 이 값이 앱 쪽 응답에 한 번이라도 보이면 실패로 센다.
    final serverKey =
        'sk-demo-server-only-${Random.secure().nextInt(1 << 32).toRadixString(16)}';
    final client = http.Client();

    ProxyConfig configFor({int? requestsPerMinute}) => ProxyConfig(
          providers: [
            ProviderConfig(
              id: 'openai',
              type: ProviderType.openai,
              prefix: '/openai',
              upstream: mock.url,
              keyEnv: 'OPENAI_API_KEY',
              keyHeader: KeyHeaderStyle.bearer,
              allowedPaths: const ['/v1/chat/completions'],
              allowedModels: const ['gpt-4o-mini'],
            ),
          ],
          appCheck: AppCheckConfig(
            mode: AppCheckMode.local,
            projectNumber: issuer.projectNumber,
            projectId: issuer.projectId,
            allowedAppIds: {issuer.appId},
            jwksUrl: jwksUrl,
          ),
          limits: LimitsConfig(
              subject: SubjectKey.appAndIp,
              requestsPerMinute: requestsPerMinute),
        );

    final servers = <HttpServer>[];
    Future<Uri> startProxy(
        {int? requestsPerMinute, bool bufferOutput = false}) async {
      final app = ProxyApp(
        configFor(requestsPerMinute: requestsPerMinute),
        jwks: HttpJwksSource(jwksUrl),
        serverKeys: {'openai': serverKey},
        logger: RequestLogger(sink: _logLines.add, lang: lang),
        bufferOutput: bufferOutput,
      );
      final server = await app.serve(host: '127.0.0.1', port: 0);
      servers.add(server);
      return Uri.parse(
          'http://127.0.0.1:${server.port}/openai/v1/chat/completions');
    }

    try {
      _out(m.t('demo.setup',
          {'jwks': jwksUrl, 'kid': issuer.kid, 'mock': mock.url}));
      _out('');

      if (only == 'all' || only == 'security') {
        await _security(issuer, await startProxy(), client, mock, serverKey);
      }
      if (only == 'all' || only == 'limits') {
        await _limits(issuer, await startProxy(requestsPerMinute: 3), client);
      }
      if (only == 'all' || only == 'buffering') {
        await _buffering(issuer, await startProxy(),
            await startProxy(bufferOutput: true), client);
      }

      // 앱이 받은 어떤 응답에도 서버 키가 없어야 한다.
      final clientSawKey = _clientSeen.toString().contains(serverKey);
      final logHasKey = _logLines.any((l) => l.contains(serverKey));
      _out(m.t('demo.client_key',
          {'value': clientSawKey ? m.t('demo.yes') : m.t('demo.no')}));
      _expect(!clientSawKey && !logHasKey);

      _out('');
      _out(m.t('demo.log_header'));
      for (final line in _logLines) {
        _out('  $line');
      }
      _out('');
      _out(_failures == 0
          ? m.t('demo.summary_ok', {'n': _checks})
          : m.t('demo.summary_fail', {'n': _failures, 'total': _checks}));
      return _failures == 0;
    } finally {
      client.close();
      for (final s in servers) {
        await s.close(force: true);
      }
      await mock.close();
      await jwksServer.close(force: true);
    }
  }

  // ---------------------------------------------------------------- [1] 보안
  Future<void> _security(AppCheckTestIssuer issuer, Uri proxy,
      http.Client client, MockUpstream mock, String serverKey) async {
    final m = _m;
    _out(m.t('demo.section_security'));

    // 정상 토큰(aud 는 2개짜리 목록) → 200 스트림
    final ok = await _send(client, proxy, token: issuer.token(), stream: true);
    final events = '\n\n'.allMatches(ok.body).length;
    _row(ok.status == 200 && events > 0, m.t('demo.s_valid'), '200 stream',
        m.t('demo.got_stream', {'status': ok.status, 'events': events}));
    final upstreamRecord = mock.requests.isEmpty ? null : mock.requests.last;

    final cases = <(String, String?, String)>[
      (m.t('demo.s_missing'), null, 'missing_token'),
      (
        m.t('demo.s_bad_aud'),
        issuer.token(
            audience: ['projects/999999999999', 'projects/someone-else']),
        'bad_aud'
      ),
      (m.t('demo.s_hs256'), issuer.forgeHs256(), 'alg_not_rs256'),
      (
        m.t('demo.s_expired'),
        issuer.token(expiresIn: const Duration(minutes: -5)),
        'expired'
      ),
      (m.t('demo.s_tampered'), issuer.tampered(), 'bad_signature'),
    ];
    for (final (label, token, reason) in cases) {
      final r = await _send(client, proxy, token: token, stream: false);
      _row(r.status == 401 && r.reason == reason, label, '401 $reason',
          '${r.status} ${r.reason ?? '-'}');
    }

    // 라이브러리의 "aud 완전 일치" 검사였다면 정상 토큰도 거부됐다 — 그래서 "포함" 검사를 한다.
    String libResult;
    try {
      JWT.verify(issuer.token(), parseJwks(issuer.jwks())[issuer.kid]!,
          audience: Audience.one('projects/${issuer.projectNumber}'));
      libResult = m.t('demo.lib_accepted');
    } catch (_) {
      libResult = m.t('demo.lib_rejected');
    }
    _out(m.t('demo.aud_note', {'result': libResult}));

    final sawServerKey =
        upstreamRecord?.headers['authorization'] == 'Bearer $serverKey';
    final sawAppCheck =
        upstreamRecord?.headers.containsKey('x-firebase-appcheck') ?? true;
    _out(m.t('demo.upstream_key',
        {'value': sawServerKey ? m.t('demo.yes') : m.t('demo.no')}));
    _out(m.t('demo.upstream_appcheck',
        {'value': sawAppCheck ? m.t('demo.yes') : m.t('demo.no')}));
    _expect(sawServerKey && !sawAppCheck);
    _out('');
  }

  // ---------------------------------------------------------------- [2] 한도
  Future<void> _limits(
      AppCheckTestIssuer issuer, Uri proxy, http.Client client) async {
    final m = _m;
    _out(m.t('demo.section_limits'));
    for (var i = 1; i <= 4; i++) {
      final r =
          await _send(client, proxy, token: issuer.token(), stream: false);
      if (i < 4) {
        _row(r.status == 200, m.t('demo.s_request', {'n': i}), '200',
            '${r.status}');
      } else {
        final retry = int.tryParse(r.headers['retry-after'] ?? '');
        final ok =
            r.status == 429 && retry != null && retry >= 1 && retry <= 60;
        _row(ok, m.t('demo.s_request', {'n': i}), '429 Retry-After 1..60',
            '${r.status} Retry-After ${r.headers['retry-after'] ?? '-'}');
      }
    }
    _out(m.t('demo.limits_note'));
    _out('');
  }

  // ---------------------------------------------------------------- [3] 버퍼링
  Future<void> _buffering(AppCheckTestIssuer issuer, Uri unbuffered,
      Uri buffered, http.Client client) async {
    final m = _m;
    _out(m.t('demo.section_buffering', {'delay': chunkDelay.inMilliseconds}));
    final off =
        await _send(client, unbuffered, token: issuer.token(), stream: true);
    final on =
        await _send(client, buffered, token: issuer.token(), stream: true);
    final offRatio = (off.firstChunkMs ?? off.totalMs) / max(1, off.totalMs);
    final onRatio = (on.firstChunkMs ?? on.totalMs) / max(1, on.totalMs);
    _row(
        off.status == 200 && offRatio < 0.5,
        m.t('demo.s_buffer_off'),
        m.t('demo.expect_early'),
        m.t('demo.got_timing',
            {'first': off.firstChunkMs ?? '-', 'total': off.totalMs}));
    _row(
        on.status == 200 && onRatio >= 0.5,
        m.t('demo.s_buffer_on'),
        m.t('demo.expect_late'),
        m.t('demo.got_timing',
            {'first': on.firstChunkMs ?? '-', 'total': on.totalMs}));
    _out(m.t('demo.buffer_note'));
    _out('');
  }

  // ---------------------------------------------------------------- 도우미
  void _row(bool ok, String scenario, String expected, String got) {
    _expect(ok);
    final mark = ok ? _m.t('demo.mark_ok') : _m.t('demo.mark_fail');
    _out(_m.t('demo.row', {
      'mark': mark,
      'scenario': scenario,
      'expected': expected,
      'got': got
    }));
  }

  void _expect(bool ok) {
    _checks++;
    if (!ok) _failures++;
  }

  Future<_Call> _send(http.Client client, Uri url,
      {String? token, required bool stream}) async {
    final request = http.Request('POST', url)
      ..headers['content-type'] = 'application/json'
      ..body = jsonEncode({
        'model': 'gpt-4o-mini',
        'stream': stream,
        'messages': [
          {'role': 'user', 'content': 'Say hello'}
        ],
      });
    if (token != null) request.headers['x-firebase-appcheck'] = token;
    final sw = Stopwatch()..start();
    final res = await client.send(request);
    int? first;
    final bytes = <int>[];
    await for (final chunk in res.stream) {
      first ??= sw.elapsedMilliseconds;
      bytes.addAll(chunk);
    }
    final body = utf8.decode(bytes, allowMalformed: true);
    _clientSeen
      ..write(body)
      ..write(res.headers);
    return _Call(
        res.statusCode, body, res.headers, first, sw.elapsedMilliseconds);
  }
}
