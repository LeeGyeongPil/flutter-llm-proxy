// AC-7: `dart run bin/flutter_llm_proxy.dart demo` works offline with no key,
// labels the mock, shows every expected outcome and exits 0.
// Runs the real executable entry point as a separate process.
import 'dart:io';

import 'package:flutter_llm_proxy/flutter_llm_proxy.dart' show packageVersion;
import 'package:test/test.dart';

Future<ProcessResult> runTool(List<String> args) => Process.run(
      Platform.resolvedExecutable, // 지금 테스트를 돌리는 그 dart
      ['run', 'bin/flutter_llm_proxy.dart', ...args],
      // 키가 있어도 쓰지 않는다는 것을 보이려고 일부러 빈 키 환경으로 돌린다.
      environment: {
        'OPENAI_API_KEY': '',
        'ANTHROPIC_API_KEY': '',
        'GEMINI_API_KEY': '',
        'FLUTTER_LLM_PROXY_LANG': '',
        'LC_ALL': '',
        'LC_MESSAGES': '',
        'LANG': 'en_US.UTF-8',
      },
    );

void main() {
  test(
      'demo: exit 0, mock labelled, all outcomes shown, key never reaches the client',
      () async {
    final r = await runTool(['demo']);
    final out = r.stdout as String;
    expect(r.exitCode, 0, reason: '$out\n${r.stderr}');
    expect(out, contains('PRACTICE MOCK MODE'));
    expect(out.toLowerCase(), contains('mock'));
    expect(out, contains('200 stream'));
    expect(out, contains('401 bad_aud'));
    expect(out, contains('401 alg_not_rs256'));
    expect(out, contains('401 expired'));
    expect(out, contains('429 Retry-After'));
    expect(RegExp(r'got 429 Retry-After \d+').hasMatch(out), isTrue);
    expect(out, contains('buffer_output=false'));
    expect(out, contains('first chunk'));
    expect(out, contains('upstream saw server key: yes'));
    expect(out, contains('client saw key: no'));
    expect(out, isNot(contains('FAIL')));
    expect(out, contains('Exit code 0.'));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('demo --only buffering: exit 0 and shows both timings', () async {
    final r = await runTool(['demo', '--only', 'buffering']);
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    expect(r.stdout as String, contains('shelf default (buffer_output=true)'));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('--version prints the package version; unknown command exits 2',
      () async {
    final v = await runTool(['--version']);
    expect(v.exitCode, 0);
    expect((v.stdout as String).trim(), 'flutter_llm_proxy $packageVersion');
    final bad = await runTool(['launch']);
    expect(bad.exitCode, 2);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
