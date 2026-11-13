import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/rules/workspace_voice_view_dependencies.dart'
    as rule;
import 'architecture_contract_test.dart' show FixtureWorkspace;

void main() {
  final cases =
      (jsonDecode(
                File(
                  'tools/architecture/fixtures/workspace_voice_views.fixture.json',
                ).readAsStringSync(),
              )
              as Map)['cases']
          as List;
  for (final value in cases.cast<Map<String, dynamic>>()) {
    test(value['name'] as String, () {
      final workspace = FixtureWorkspace(value);
      addTearDown(workspace.dispose);
      if (value['inputError'] == true) {
        expect(() => rule.check(workspace.snapshot), throwsFormatException);
        return;
      }
      final findings = rule.check(workspace.snapshot);
      expect(findings.isNotEmpty, value['expect']);
      for (final finding in findings) {
        expect(finding.id, rule.id);
        expect(finding.file, rule.view);
        expect(finding.line, value['line']);
      }
    });
  }
}
