import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/dart_sdk.dart';
import '../tools/architecture/proof_process.dart';
import '../tools/architecture/rules/recent_capture_release_safe.dart' as rule;

const _invalid = '''
import 'package:flutter/rendering.dart' as rendering;
typedef Boundary = rendering.RenderRepaintBoundary;
bool direct(Boundary boundary) => boundary.debugNeedsPaint;
bool? nullable(Boundary? boundary) => boundary?.debugNeedsPaint;
Boundary cascade(Boundary boundary) => boundary..debugNeedsPaint;
class Inherited extends rendering.RenderRepaintBoundary {
  bool capture() => debugNeedsPaint;
}
''';

const _valid = '''
import 'package:flutter/rendering.dart' as rendering;
import 'package:flutter/scheduler.dart';
class Unrelated {
  bool get debugNeedsPaint => false;
}
bool ordinary(Unrelated value) => value.debugNeedsPaint;
class Checked extends rendering.RenderRepaintBoundary {
  Checked(rendering.RenderObject other) : assert(!other.debugNeedsPaint);
  bool checked() {
    assert(!debugNeedsPaint);
    assert(() { return !debugNeedsPaint; }());
    return true;
  }
}
Future<void> capture(rendering.RenderRepaintBoundary boundary) async {
  await SchedulerBinding.instance.endOfFrame;
  assert(!boundary.debugNeedsPaint);
  await boundary.toImage();
}
''';

void main() {
  test('production recent capture is safe with assertions disabled', () async {
    expect(await rule.check(Directory.current), isEmpty);
  });

  late Directory root;
  late File target;
  setUp(() {
    root = Directory.systemTemp.createTempSync('wing-capture-guard-');
    addTearDown(() => root.deleteSync(recursive: true));
    final original = File('.dart_tool/package_config.json').absolute;
    final config = jsonDecode(original.readAsStringSync()) as Map;
    target = File('${root.path}/${rule.owner}');
    target.parent.createSync(recursive: true);
    final fixtureConfig = File('${root.path}/.dart_tool/package_config.json');
    fixtureConfig.parent.createSync(recursive: true);
    fixtureConfig.writeAsStringSync(
      jsonEncode({
        ...config,
        'packages': [
          for (final package in config['packages'] as List)
            {
              ...package as Map,
              'rootUri': package['name'] == 'wing'
                  ? root.uri.toString()
                  : original.uri.resolve(package['rootUri']).toString(),
            },
        ],
      }),
    );
  });

  test('resolved Flutter reads report every unsafe capture location', () async {
    target.writeAsStringSync(_invalid);
    final findings = await rule.check(root);
    expect(findings, hasLength(4));
    expect(findings.map((finding) => finding.id).toSet(), {rule.id});
    expect(findings.map((finding) => finding.file).toSet(), {rule.owner});
    expect(findings.map((finding) => finding.line).toSet(), {3, 4, 5, 7});
    final result = await _cli(root);
    expect(result.exitCode, 1, reason: _output(result));
    expect(result.stdout, contains(rule.id));
  });

  test(
    'assert-only Flutter reads and unrelated getters are admitted',
    () async {
      target.writeAsStringSync(_valid);
      expect(await rule.check(root), isEmpty);
      final result = await _cli(root);
      expect(result.exitCode, 0, reason: _output(result));
    },
  );

  for (final fixture in <String, String?>{
    'missing owner': null,
    'unresolved paint read':
        'bool capture(Unknown value) => value.debugNeedsPaint;',
    'dynamic paint read':
        'bool capture(dynamic value) => value.debugNeedsPaint;',
    'malformed owner': 'class Capture {',
    'uninspected part': "part 'capture_part.dart';",
    'conditional capture namespace':
        "import 'a.dart' if (dart.library.io) 'b.dart';",
  }.entries) {
    test(
      '${fixture.key} fails input rather than certifying capture safety',
      () async {
        if (fixture.value case final source?) target.writeAsStringSync(source);
        await expectLater(rule.check(root), throwsFormatException);
        final result = await _cli(root);
        expect(result.exitCode, 2, reason: _output(result));
        expect(result.stderr, contains('${rule.id} INPUT'));
      },
    );
  }
}

Future<ProcessResult> _cli(Directory root) =>
    runProofProcess('${dartSdkPath(Directory.current.path)}/bin/dart', [
      'run',
      'tools/architecture/rules/recent_capture_release_safe.dart',
      '--root',
      root.path,
    ]);

String _output(ProcessResult result) => '${result.stdout}\n${result.stderr}';
