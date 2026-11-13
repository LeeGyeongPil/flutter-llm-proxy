// One version everywhere: pubspec.yaml, the --version output (packageVersion)
// and the CHANGELOG heading.
import 'dart:io';

import 'package:flutter_llm_proxy/flutter_llm_proxy.dart' show packageVersion;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('pubspec version == packageVersion == latest CHANGELOG entry', () {
    final pubspec =
        loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    expect(pubspec['version'], packageVersion);
    final changelog = File('CHANGELOG.md').readAsStringSync();
    final first =
        RegExp(r'^## (\S+)', multiLine: true).firstMatch(changelog)!.group(1);
    expect(first, packageVersion);
  });
}
