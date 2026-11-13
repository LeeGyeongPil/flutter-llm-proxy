// AC-10: the lowest Dart in the CI matrix, pubspec.yaml's SDK floor and
// pubspec.lock's SDK floor agree; the lock only has hosted packages; every
// locked package (dev ones too) accepts that floor.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// "3.5.0" -> [3, 5, 0] (pre-release suffix ignored).
List<int> parseVersion(String v) =>
    v.split('-').first.split('.').map(int.parse).toList();

int compareVersions(String a, String b) {
  final x = parseVersion(a);
  final y = parseVersion(b);
  for (var i = 0; i < 3; i++) {
    if (x[i] != y[i]) return x[i].compareTo(y[i]);
  }
  return 0;
}

/// Lower bound of an SDK constraint: "^3.5.0", ">=3.5.0 <4.0.0", ">=2.12.0-0 <3.0.0".
String lowerBound(String constraint) {
  final caret = RegExp(r'\^(\d+\.\d+\.\d+)').firstMatch(constraint);
  if (caret != null) return caret.group(1)!;
  final ge = RegExp(r'>=\s*(\d+\.\d+\.\d+)').firstMatch(constraint);
  if (ge != null) return ge.group(1)!;
  throw FormatException('no lower bound in "$constraint"');
}

void main() {
  final pubspec = loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
  final lockText = File('pubspec.lock').readAsStringSync();
  final lock = loadYaml(lockText) as YamlMap;
  final ci =
      loadYaml(File('.github/workflows/ci.yml').readAsStringSync()) as YamlMap;

  final pubspecFloor =
      lowerBound((pubspec['environment'] as YamlMap)['sdk'] as String);
  final lockFloor = lowerBound((lock['sdks'] as YamlMap)['dart'] as String);
  final matrix = (((ci['jobs'] as YamlMap)['test'] as YamlMap)['strategy']
      as YamlMap)['matrix'] as YamlMap;
  final sdks = (matrix['sdk'] as YamlList).map((e) => '$e').toList();
  final pinned = sdks
      .where((s) => RegExp(r'^\d+\.\d+\.\d+$').hasMatch(s))
      .toList()
    ..sort(compareVersions);

  test('pubspec.yaml SDK floor == pubspec.lock SDK floor', () {
    expect(pubspecFloor, lockFloor);
  });

  test('lowest CI matrix version == that floor, and stable is tested too', () {
    expect(pinned, isNotEmpty);
    expect(compareVersions(pinned.first, lockFloor), greaterThanOrEqualTo(0));
    expect(pinned.first, pubspecFloor, reason: 'test the floor we promise');
    expect(sdks, contains('stable'));
  });

  test(
      'lock has only hosted packages; pubspec has no overrides or path dependencies',
      () {
    expect(lockText, isNot(contains('source: path')));
    expect(lockText, isNot(contains('source: git')));
    expect(pubspec.containsKey('dependency_overrides'), isFalse);
    for (final section in ['dependencies', 'dev_dependencies']) {
      final deps = pubspec[section] as YamlMap? ?? YamlMap();
      for (final entry in deps.entries) {
        expect(entry.value is String, isTrue,
            reason:
                '$section.${entry.key} must be a hosted version constraint');
      }
    }
    expect(File('pubspec_overrides.yaml').existsSync(), isFalse);
  });

  test('test is pinned to 1.25.15 (newer test needs a newer SDK)', () {
    expect((pubspec['dev_dependencies'] as YamlMap)['test'], '1.25.15');
    final locked = (lock['packages'] as YamlMap)['test'] as YamlMap;
    expect(locked['version'], '1.25.15');
  });

  test('every locked package (dev too) accepts the SDK floor', () {
    // pub get 이 만든 package_config 로 각 패키지의 pubspec 을 찾아 SDK 하한을 읽는다(네트워크 없음).
    final config =
        jsonDecode(File('.dart_tool/package_config.json').readAsStringSync())
            as Map<String, dynamic>;
    final base = File('.dart_tool/package_config.json').absolute.uri;
    final locked = (lock['packages'] as YamlMap).keys.map((k) => '$k').toSet();
    final tooNew = <String>[];
    var checked = 0;
    for (final p in (config['packages'] as List).cast<Map<String, dynamic>>()) {
      final name = p['name'] as String;
      if (!locked.contains(name)) continue;
      final rootUri = p['rootUri'] as String;
      final root = base.resolve(rootUri.endsWith('/') ? rootUri : '$rootUri/');
      final file = File.fromUri(root.resolve('pubspec.yaml'));
      final spec = loadYaml(file.readAsStringSync()) as YamlMap;
      final sdk = (spec['environment'] as YamlMap?)?['sdk'] as String?;
      if (sdk == null) continue;
      checked++;
      if (compareVersions(lowerBound(sdk), pubspecFloor) > 0)
        tooNew.add('$name ($sdk)');
    }
    expect(checked, locked.length);
    expect(tooNew, isEmpty,
        reason: 'these need a newer Dart than $pubspecFloor');
  });
}
