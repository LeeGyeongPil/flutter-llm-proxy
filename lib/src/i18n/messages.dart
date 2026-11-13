import 'messages_en.dart';
import 'messages_ko.dart';

/// Languages for CLI help, CLI output and request logs.
/// Error codes in HTTP responses stay English on purpose (apps match on them).
enum Lang { en, ko }

/// Environment variable that picks the language when `--lang` is absent.
const String langEnvVar = 'FLUTTER_LLM_PROXY_LANG';

/// Picks the language: `--lang` > FLUTTER_LLM_PROXY_LANG > LC_ALL >
/// LC_MESSAGES > LANG. Anything that is not Korean falls back to English.
Lang resolveLang({String? flag, required Map<String, String> env}) {
  final explicit = _parse(flag) ?? _parse(env[langEnvVar]);
  if (explicit != null) return explicit;
  // POSIX 순서: LC_ALL 이 있으면 그것, 없으면 LC_MESSAGES, 없으면 LANG.
  for (final name in const ['LC_ALL', 'LC_MESSAGES', 'LANG']) {
    final v = env[name];
    if (v == null || v.isEmpty) continue;
    return v.toLowerCase().startsWith('ko') ? Lang.ko : Lang.en;
  }
  return Lang.en;
}

Lang? _parse(String? v) {
  if (v == null || v.isEmpty) return null;
  final s = v.toLowerCase();
  if (s == 'ko' || s.startsWith('ko_') || s.startsWith('ko-')) return Lang.ko;
  if (s == 'en' || s.startsWith('en_') || s.startsWith('en-')) return Lang.en;
  return null;
}

/// Message table lookup with `{name}` placeholders.
class Messages {
  const Messages(this.lang);
  final Lang lang;

  static Map<String, String> table(Lang lang) =>
      lang == Lang.ko ? messagesKo : messagesEn;

  String t(String key, [Map<String, Object?> args = const {}]) {
    // 없는 키는 영어로, 영어에도 없으면 키 자체를 보여 준다(테스트가 키 집합 일치를 확인한다).
    var text = table(lang)[key] ?? messagesEn[key] ?? key;
    args.forEach((name, value) {
      text = text.replaceAll('{$name}', '$value');
    });
    return text;
  }
}
