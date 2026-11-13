// AC-8: English / Korean output, language precedence, and identical
// message key sets.
import 'package:flutter_llm_proxy/src/cli.dart';
import 'package:flutter_llm_proxy/src/i18n/messages.dart';
import 'package:flutter_llm_proxy/src/i18n/messages_en.dart';
import 'package:flutter_llm_proxy/src/i18n/messages_ko.dart';
import 'package:test/test.dart';

import 'support/harness.dart' show hangul;

Future<String> run(List<String> args,
    {Map<String, String> env = const {}}) async {
  final lines = <String>[];
  await runCli(args, environment: env, out: lines.add, err: lines.add);
  return lines.join('\n');
}

void main() {
  group('message tables', () {
    test('en and ko have exactly the same keys', () {
      expect(
          messagesKo.keys.toSet().difference(messagesEn.keys.toSet()), isEmpty,
          reason: 'only in ko');
      expect(
          messagesEn.keys.toSet().difference(messagesKo.keys.toSet()), isEmpty,
          reason: 'only in en');
    });

    test('each key uses the same {placeholders} in both languages', () {
      final ph = RegExp(r'\{(\w+)\}');
      for (final key in messagesEn.keys) {
        final en =
            ph.allMatches(messagesEn[key]!).map((m) => m.group(1)).toSet();
        final ko =
            ph.allMatches(messagesKo[key]!).map((m) => m.group(1)).toSet();
        expect(ko, en, reason: key);
      }
    });

    test('English table has no Hangul; every Korean UI sentence is translated',
        () {
      for (final e in messagesEn.entries) {
        expect(hangul.hasMatch(e.value), isFalse, reason: e.key);
      }
      final translated =
          messagesKo.entries.where((e) => hangul.hasMatch(e.value)).length;
      expect(translated / messagesKo.length, greaterThan(0.8));
    });
  });

  group('language precedence', () {
    test('--lang > FLUTTER_LLM_PROXY_LANG > LC_ALL > LC_MESSAGES > LANG', () {
      expect(
          resolveLang(
              flag: 'en',
              env: {'FLUTTER_LLM_PROXY_LANG': 'ko', 'LANG': 'ko_KR.UTF-8'}),
          Lang.en);
      expect(
          resolveLang(
              env: {'FLUTTER_LLM_PROXY_LANG': 'ko', 'LANG': 'en_US.UTF-8'}),
          Lang.ko);
      expect(resolveLang(env: {'LANG': 'ko_KR.UTF-8'}), Lang.ko);
      expect(resolveLang(env: {'LC_ALL': 'en_US.UTF-8', 'LANG': 'ko_KR.UTF-8'}),
          Lang.en);
      expect(
          resolveLang(
              env: {'LC_MESSAGES': 'ko_KR.UTF-8', 'LANG': 'en_US.UTF-8'}),
          Lang.ko);
      expect(resolveLang(env: {'LANG': 'ja_JP.UTF-8'}), Lang.en);
      expect(resolveLang(env: {'LANG': 'C'}), Lang.en);
      expect(resolveLang(env: {}), Lang.en);
      expect(resolveLang(flag: 'xx', env: {'LANG': 'ko_KR.UTF-8'}), Lang.ko,
          reason: 'unknown flag is ignored here');
    });

    test('the CLI follows the same order', () async {
      final viaEnv = await run(['--help'],
          env: {'FLUTTER_LLM_PROXY_LANG': 'ko', 'LANG': 'en_US.UTF-8'});
      expect(hangul.hasMatch(viaEnv), isTrue);
      final flagWins = await run(['--help', '--lang', 'en'],
          env: {'FLUTTER_LLM_PROXY_LANG': 'ko', 'LANG': 'ko_KR.UTF-8'});
      expect(hangul.hasMatch(flagWins), isFalse);
      final langOnly = await run(['--help'], env: {'LANG': 'ko_KR.UTF-8'});
      expect(hangul.hasMatch(langOnly), isTrue);
      final other = await run(['--help'], env: {'LANG': 'fr_FR.UTF-8'});
      expect(hangul.hasMatch(other), isFalse);
    });

    test('--lang with an unknown value is a usage error (exit 2)', () async {
      expect(
          await runCli(['--lang', 'fr', '--help'],
              environment: const {}, out: (_) {}, err: (_) {}),
          2);
    });
  });

  test('missing config file: short hint in both languages, no line/key noise',
      () async {
    final en =
        await run(['check-config', 'nope.yaml'], env: {'LANG': 'en_US.UTF-8'});
    expect(en, contains('nope.yaml'));
    expect(en, contains('example/proxy.yaml'));
    expect(en, isNot(contains('line 0')));
    final ko = await run(['--lang', 'ko', 'check-config', 'nope.yaml']);
    expect(ko, contains('nope.yaml'));
    expect(hangul.hasMatch(ko), isTrue);
    expect(ko, isNot(contains('line 0')));
  });

  group('each command in each language', () {
    final commands = <String, List<String>>{
      'help': ['--help'],
      'serve help': ['serve', '--help'],
      'demo help': ['demo', '--help'],
      'check-config help': ['check-config', '--help'],
      'check-config': ['check-config', 'example/proxy.yaml'],
      'config error': ['check-config', 'pubspec.yaml'],
    };
    commands.forEach((name, args) {
      test('$name: ko has Hangul, en has none', () async {
        final ko = await run([...args, '--lang', 'ko']);
        final en = await run([...args, '--lang', 'en']);
        expect(hangul.hasMatch(ko), isTrue, reason: ko);
        expect(hangul.hasMatch(en), isFalse, reason: en);
        expect(ko, isNot(en));
      });
    });

    test('demo: ko has Hangul, en has none (security part)', () async {
      final ko = await run(
          ['demo', '--only', 'security', '--delay-ms', '20', '--lang', 'ko']);
      final en = await run(
          ['demo', '--only', 'security', '--delay-ms', '20', '--lang', 'en']);
      expect(hangul.hasMatch(ko), isTrue);
      expect(ko, contains('업스트림이 서버 키를 받음: 예'));
      expect(hangul.hasMatch(en), isFalse, reason: en);
      expect(en, contains('upstream saw server key: yes'));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
