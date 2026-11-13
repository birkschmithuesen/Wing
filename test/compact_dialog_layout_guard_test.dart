import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/dart_sdk.dart';
import '../tools/architecture/rules/compact_dialog_layout.dart' as rule;
import 'architecture_contract_test.dart' show FixtureWorkspace;

void main() {
  for (final call in [
    'AlertDialog(title: Text("Review"))',
    'const AlertDialog()',
    'material.AlertDialog()',
    'SimpleDialog()',
    'Alias()',
    'AlertDialog.new',
    'material.AlertDialog.new',
    'Alias.new',
    'AlertDialog.adaptive()',
    'material.AlertDialog.adaptive()',
  ]) {
    test('rejects native popup $call', () {
      final workspace = FixtureWorkspace({
        'files': {
          'lib/barrel.dart': {
            'role': 'presentation',
            'source': "export 'package:flutter/material.dart';",
          },
          'lib/view.dart': {
            'role': 'view',
            'source':
                "import 'barrel.dart'; import 'barrel.dart' as material; typedef Alias = AlertDialog; Object build() => $call;",
          },
        },
      });
      addTearDown(workspace.dispose);
      final findings = rule.check(workspace.snapshot);
      expect(findings, hasLength(1));
      expect(findings.single.id, rule.id);
      expect(findings.single.file, 'lib/view.dart');
    });
  }
  test('rejects an inherited native alert frame', () {
    final workspace = FixtureWorkspace({
      'files': {
        'lib/view.dart': {
          'role': 'view',
          'source':
              "import 'package:flutter/material.dart'; class CustomPopup extends AlertDialog {}",
        },
      },
    });
    addTearDown(workspace.dispose);
    expect(rule.check(workspace.snapshot).single.id, rule.id);
  });
  test('conditional exports and parts retain popup identity', () {
    final workspace = FixtureWorkspace({
      'files': {
        'lib/barrel.dart': {
          'role': 'presentation',
          'source':
              "export 'local.dart' if (dart.library.ui) 'package:flutter/material.dart';",
        },
        'lib/local.dart': {'role': 'presentation', 'source': 'class Local {}'},
        'lib/view.dart': {
          'role': 'view',
          'source': "import 'barrel.dart'; part 'popup.dart';",
        },
        'lib/popup.dart': {
          'role': 'view',
          'library': 'lib/view.dart',
          'source': "part of 'view.dart'; Object build() => AlertDialog();",
        },
      },
    });
    addTearDown(workspace.dispose);
    expect(rule.check(workspace.snapshot).single.file, 'lib/popup.dart');
  });
  test('shared owner and unrelated factories are valid', () {
    final workspace = FixtureWorkspace({
      'files': {
        rule.owner: {
          'role': 'view',
          'source':
              "import 'package:flutter/material.dart'; Object build() => AlertDialog();",
        },
        'lib/view.dart': {
          'role': 'view',
          'source':
              "import 'package:flutter/material.dart' hide AlertDialog; class AlertDialog { AlertDialog(); } Object build() => AlertDialog();",
        },
        'lib/shadow.dart': {
          'role': 'view',
          'source':
              "import 'package:flutter/material.dart'; Object build(Function AlertDialog) => AlertDialog(); Object other(Object material) => material.SimpleDialog();",
        },
      },
    });
    addTearDown(workspace.dispose);
    expect(rule.check(workspace.snapshot), isEmpty);
  });
  test('CLI rejects the defect and accepts shared framing', () async {
    final workspace = FixtureWorkspace({
      'files': {
        'lib/view.dart': {
          'role': 'view',
          'source':
              "import 'package:flutter/material.dart'; Object build() => AlertDialog();",
        },
      },
    });
    addTearDown(workspace.dispose);
    final directory = await Directory.systemTemp.createTemp('wing-dialog-cli-');
    addTearDown(() => directory.delete(recursive: true));
    final dart = '${dartSdkPath(Directory.current.path)}/bin/dart';
    final kernel = '${directory.path}/rule.dill';
    // Compile the actual entry point once; each verdict still uses a fresh VM.
    final compiled = await Process.run(dart, [
      'compile',
      'kernel',
      'tools/architecture/rules/compact_dialog_layout.dart',
      '-o',
      kernel,
    ]);
    expect(
      compiled.exitCode,
      0,
      reason: '${compiled.stdout}\n${compiled.stderr}',
    );
    Future<ProcessResult> run() => Process.run(dart, [
      kernel,
      '--root',
      workspace.directory.path,
      '--roles',
      workspace.rolesPath,
      '--json',
    ]);
    final rejected = await run();
    expect(
      rejected.exitCode,
      1,
      reason: '${rejected.stdout}\n${rejected.stderr}',
    );
    expect(rejected.stdout, contains(rule.id));
    File(
      '${workspace.directory.path}/lib/view.dart',
    ).writeAsStringSync('Object build() => StudioDialog();');
    final accepted = await run();
    expect(
      accepted.exitCode,
      0,
      reason: '${accepted.stdout}\n${accepted.stderr}',
    );
  });
}
