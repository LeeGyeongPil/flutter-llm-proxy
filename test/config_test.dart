// AC-9: check-config summary and exit codes, config errors with line number
// and key path, and serve refusing insecure settings on a public host.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_llm_proxy/flutter_llm_proxy.dart';
import 'package:flutter_llm_proxy/src/cli.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

class CliRun {
  CliRun(this.code, this.out, this.err);
  final int code;
  final String out;
  final String err;
}

Future<CliRun> cli(List<String> args,
    {Map<String, String> env = const {},
    Future<void>? stop,
    List<String>? sink}) async {
  final out = sink ?? <String>[];
  final err = <String>[];
  final code = await runCli(args,
      environment: env, out: out.add, err: err.add, stopSignal: stop);
  return CliRun(code, out.join('\n'), err.join('\n'));
}

const validYaml = '''
providers:
  openai:
    allowed_models: [gpt-4o-mini]
app_check:
  mode: firebase
  project_number: "123456789012"
limits:
  requests_per_minute: 10
''';

void main() {
  late Directory tmp;
  setUpAll(() => tmp = Directory.systemTemp.createTempSync('flp_config_'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  String write(String name, String text) {
    final f = File('${tmp.path}/$name')..writeAsStringSync(text);
    return f.path;
  }

  group('check-config example/proxy.yaml', () {
    test(
        'exit 0 with a summary; key env vars shown as set / not set, never their values',
        () async {
      final r = await cli(
          ['check-config', 'example/proxy.yaml', '--lang', 'en'],
          env: {'OPENAI_API_KEY': 'sk-live-should-never-print-123'});
      expect(r.code, 0, reason: r.err);
      expect(r.out, contains('openai (openai)'));
      expect(r.out, contains('anthropic (anthropic)'));
      expect(r.out, contains('gemini (gemini)'));
      expect(r.out, contains('models: gpt-4o-mini'));
      expect(r.out, contains('subject app+ip, 20 requests/min'));
      expect(r.out, contains('OPENAI_API_KEY via bearer [set]'));
      expect(r.out, contains('ANTHROPIC_API_KEY via x-api-key [not set]'));
      expect(r.out, isNot(contains('sk-live-should-never-print-123')));
      expect(r.out, contains('Config is valid.'));
    });

    test('--strict turns warnings into exit 1', () async {
      final r = await cli(
          ['check-config', 'example/proxy.yaml', '--strict', '--lang', 'en']);
      expect(r.code, 1);
      expect(r.err, contains('--strict'));
    });

    test('the example parses to the documented values', () {
      final c = ProxyConfig.load('example/proxy.yaml');
      expect(c.providers.map((p) => p.id), ['openai', 'anthropic', 'gemini']);
      expect(c.providers[2].keyHeader, KeyHeaderStyle.xGoogApiKey);
      expect(c.appCheck.allowedAppIds, hasLength(3));
      expect(c.limits.subject, SubjectKey.appAndIp);
      expect(c.trustForwardedFor, isFalse);
    });
  });

  group('invalid configs exit 2 with line number and key path', () {
    final cases = <String, (String, String, int)>{
      'unknown key header style': (
        validYaml.replaceFirst('allowed_models: [gpt-4o-mini]',
            'allowed_models: [gpt-4o-mini]\n    key_header: x-custom'),
        'providers.openai.key_header',
        4,
      ),
      'negative limit': (
        validYaml.replaceFirst(
            'requests_per_minute: 10', 'requests_per_minute: -5'),
        'limits.requests_per_minute',
        8,
      ),
      'missing project_number': (
        validYaml.replaceFirst('  project_number: "123456789012"\n', ''),
        'app_check.project_number',
        5,
      ),
      'unknown top-level key': (
        '${validYaml}rate_limits: {}\n',
        'rate_limits',
        9
      ),
      'project ID where the number belongs': (
        validYaml.replaceFirst('"123456789012"', 'my-project'),
        'app_check.project_number',
        6,
      ),
    };
    cases.forEach((name, c) {
      final (yaml, keyPath, line) = c;
      test(name, () async {
        final file = write('bad_${name.replaceAll(' ', '_')}.yaml', yaml);
        final r = await cli(['check-config', file, '--lang', 'en']);
        expect(r.code, 2, reason: r.out);
        expect(r.err, contains('key $keyPath'));
        expect(r.err, contains('line $line'));
        // 라이브러리 예외에도 같은 정보가 있다.
        expect(
            () => ProxyConfig.load(file),
            throwsA(isA<ConfigException>()
                .having((e) => e.keyPath, 'keyPath', keyPath)
                .having((e) => e.line, 'line', line)));
      });
    });

    test('missing file / YAML syntax error -> exit 2', () async {
      expect((await cli(['check-config', '${tmp.path}/nope.yaml'])).code, 2);
      final broken = write('broken.yaml', 'providers: [\n');
      expect((await cli(['check-config', broken])).code, 2);
    });
  });

  group('serve guards', () {
    final devYaml = '''
providers:
  openai: {}
app_check:
  mode: local
  project_number: "123456789012"
  jwks_url: http://127.0.0.1:9/never-called
  dev_tokens: ["local-dev-token-abc"]
''';
    final offYaml = '''
providers:
  openai: {}
app_check:
  mode: off
''';

    test('dev_tokens on 0.0.0.0 -> exit 2', () async {
      final r = await cli([
        'serve',
        '--config',
        write('dev.yaml', devYaml),
        '--mock',
        '--host',
        '0.0.0.0',
        '--lang',
        'en'
      ]);
      expect(r.code, 2);
      expect(r.err, contains('Refusing to listen on 0.0.0.0'));
    });

    test('app_check.mode off on 0.0.0.0 -> exit 2', () async {
      final r = await cli([
        'serve',
        '--config',
        write('off.yaml', offYaml),
        '--mock',
        '--host',
        '0.0.0.0'
      ]);
      expect(r.code, 2);
    });

    test('real mode without the key environment variable -> exit 2', () async {
      final r = await cli(
          ['serve', '--config', write('valid.yaml', validYaml), '--lang', 'en'],
          env: {});
      expect(r.code, 2);
      expect(r.err, contains('OPENAI_API_KEY'));
    });

    test(
        'dev token on 127.0.0.1 with --mock runs, serves, and stops with exit 0',
        () async {
      final stop = Completer<void>();
      final lines = <String>[];
      final running = cli([
        'serve',
        '--config',
        write('dev2.yaml', devYaml),
        '--mock',
        '--port',
        '0',
        '--lang',
        'en'
      ], stop: stop.future, sink: lines);
      // 시작 줄에서 포트를 읽는다.
      final started = DateTime.now();
      String? url;
      while (url == null &&
          DateTime.now().difference(started) < const Duration(seconds: 10)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final m = lines
            .map(RegExp(r'listening on (http://\S+)').firstMatch)
            .whereType<RegExpMatch>()
            .firstOrNull;
        url = m?.group(1);
      }
      expect(url, isNotNull, reason: lines.join('\n'));
      expect(lines.join('\n'), contains('MOCK MODE (practice)'));

      final res = await http.post(Uri.parse('$url/openai/v1/chat/completions'),
          headers: {
            'x-firebase-appcheck': 'local-dev-token-abc',
            'content-type': 'application/json'
          },
          body: jsonEncode({'model': 'gpt-4o-mini', 'messages': []}));
      expect(res.statusCode, 200);
      expect(res.body, contains('mock upstream'));
      final health = await http.get(Uri.parse('$url/healthz'));
      expect(health.statusCode, 200);

      stop.complete();
      final r = await running;
      expect(r.code, 0);
      expect(r.out, isNot(contains('local-dev-token-abc')),
          reason: 'dev tokens are redacted from logs');
    });
  });
}
