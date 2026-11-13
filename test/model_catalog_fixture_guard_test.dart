import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/rules/model_catalog_fixture.dart' as rule;

String producer(String rows) =>
    '''
Object get(String path) {
  if (path == 'model/options') return {'providers': $rows};
  return {};
}
''';

void main() {
  const valid = "[{'slug': 'p', 'name': 'P', 'models': ['m']}]";
  const invalid = "[{'slug': 'p', 'name': 'P', 'models': [{'id': 'm'}]}]";

  test('actual authored catalog producers follow stock shape', () {
    expect(rule.check(Directory.current), isEmpty);
  });
  test('string IDs and unrelated map-shaped responses are valid', () {
    expect(rule.checkSource(producer(valid), 'fixture.dart'), isEmpty);
    expect(
      rule.checkSource(
        "Object f() => {'providers': [{'id': 'other'}]};",
        'unrelated.dart',
      ),
      isEmpty,
    );
    expect(
      rule.checkSource(
        "Object f() => {'models': [{'id': 'rejection'}]};",
        'negative_parser.dart',
      ),
      isEmpty,
    );
  });
  test('missing names, aliases and map or nonstring model IDs fail', () {
    for (final rows in [
      invalid,
      "[{'slug': 'p', 'models': ['m']}]",
      "[{'id': 'p', 'name': 'P', 'models': ['m']}]",
      "[{'slug': 'p', 'name': 'P', 'models': [42]}]",
    ]) {
      final findings = rule.checkSource(producer(rows), 'fixture.dart');
      expect(findings, isNotEmpty);
      expect(findings.first.id, rule.id);
      expect(findings.first.line, 2);
    }
  });
  test('conditional rows and switch producers are checked', () {
    expect(
      rule.checkSource(
        producer('[if (ready) ${valid.substring(1, valid.length - 1)}]'),
        'conditional.dart',
      ),
      isEmpty,
    );
    expect(
      rule.checkSource(
        "Object get(String path) => switch(path) {"
            "'model/options' => {'providers': $invalid}, _ => {}};",
        'switch.dart',
      ),
      isNotEmpty,
    );
  });
  test('decoded and adjacent route literals cannot bypass the contract', () {
    for (final literal in [
      r"'model\u002foptions'",
      "'model' '/' 'options'",
      "'m' 'o' 'd' 'e' 'l' '/' 'o' 'p' 't' 'i' 'o' 'n' 's'",
    ]) {
      expect(
        rule.checkSource(
          producer(invalid).replaceFirst("'model/options'", literal),
          'encoded.dart',
        ),
        isNotEmpty,
      );
      expect(
        rule.checkSource(
          producer(valid).replaceFirst("'model/options'", literal),
          'encoded.dart',
        ),
        isEmpty,
      );
    }
    expect(
      rule.checkSource(
        producer("[{'slug': 'p', 'name': '', 'models': ['m']}]"),
        'empty_display_name.dart',
      ),
      isEmpty,
    );
  });
  test('computed catalogs require explicit guard adaptation', () {
    expect(
      () => rule.checkSource(producer('computed'), 'computed.dart'),
      throwsFormatException,
    );
  });
  test(
    'actual CLI has invalid, valid and input-error exits',
    () async {
      final root = await Directory.systemTemp.createTemp('wing-model-fixture-');
      addTearDown(() => root.delete(recursive: true));
      final folder = Directory('${root.path}/test')..createSync();
      final file = File('${folder.path}/fixture.dart');
      for (final example in [
        (producer(invalid), 1),
        (producer(valid), 0),
        (producer('computed'), 2),
      ]) {
        file.writeAsStringSync(example.$1);
        final result = await Process.run('dart', [
          'run',
          'tools/architecture/rules/model_catalog_fixture.dart',
          '--root',
          root.path,
        ]);
        expect(
          result.exitCode,
          example.$2,
          reason: '${result.stdout}\n${result.stderr}',
        );
        if (example.$2 == 1) expect(result.stdout, contains('fixture.dart:2'));
        if (example.$2 == 2) expect(result.stderr, contains('INPUT'));
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
