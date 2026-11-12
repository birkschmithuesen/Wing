import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/dart_sdk.dart';
import '../tools/architecture/rules/form_confirmation_actions.dart' as rule;
import 'architecture_contract_test.dart' show FixtureWorkspace;

void main() {
  for (final expression in [
    "TextButton(onPressed: save, child: Text('Save'))",
    "const FilledButton(child: Text('Cancel'))",
    "material.ElevatedButton(child: material.Text('Create task'))",
    "FilledButton.icon(label: Text('Use model'))",
    "Alias(child: Text('Apply'))",
  ]) {
    test('rejects divergent footer $expression', () {
      final workspace = FixtureWorkspace({
        'files': {
          'lib/barrel.dart': {
            'role': 'presentation',
            'source': "export 'package:flutter/material.dart';",
          },
          'lib/view.dart': {
            'role': 'view',
            'source':
                """
import 'barrel.dart';
import 'barrel.dart' as material;
typedef Alias = FilledButton;
Object save() => 0;
Object build() => $expression;
""",
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

  test('part and conditional barrel retain the Flutter footer identity', () {
    final workspace = FixtureWorkspace({
      'files': {
        'lib/conditional.dart': {
          'role': 'presentation',
          'source':
              "export 'plain.dart' if (dart.library.ui) 'package:flutter/material.dart';",
        },
        'lib/plain.dart': {
          'role': 'presentation',
          'source': 'class Unrelated {}',
        },
        'lib/view.dart': {
          'role': 'view',
          'source': "import 'conditional.dart'; part 'footer.dart';",
        },
        'lib/footer.dart': {
          'role': 'view',
          'library': 'lib/view.dart',
          'source':
              "part of 'view.dart'; Object build() => FilledButton(child: Text('Save changes'));",
        },
      },
    });
    addTearDown(workspace.dispose);
    final finding = rule.check(workspace.snapshot).single;
    expect(finding.id, rule.id);
    expect(finding.file, 'lib/footer.dart');
  });
  test('unrelated local factory is not a Flutter footer', () {
    final workspace = FixtureWorkspace({
      'files': {
        'lib/view.dart': {
          'role': 'view',
          'source': """
import 'package:flutter/material.dart' hide FilledButton;
Object FilledButton({Object? child}) => 0;
Object build() => FilledButton(child: Text('Save'));
""",
        },
      },
    });
    addTearDown(workspace.dispose);
    expect(rule.check(workspace.snapshot), isEmpty);
  });

  test('lexically bound factory and namespace names stay unrelated', () {
    final workspace = FixtureWorkspace({
      'files': {
        'lib/view.dart': {
          'role': 'view',
          'source': """
import 'package:flutter/material.dart';
Object build(Function FilledButton) => FilledButton(child: Text('Save'));
Object other(Object material) => material.TextButton(child: Text('Cancel'));
Object local() { Object TextButton({Object? child}) => 0; return TextButton(child: Text('Save')); }
class Local { Object FilledButton({Object? child}) => 0; Object build() => FilledButton(child: Text('Save')); }
""",
        },
      },
    });
    addTearDown(workspace.dispose);
    expect(rule.check(workspace.snapshot), isEmpty);
  });
  for (final body in [
    "Object build(Function Text) => FilledButton(child: Text('Save'));",
    "Object build(Function material) => FilledButton(child: material.Text('Save'));",
    "Object build() { Object Text(String value) => 0; return FilledButton(child: Text('Save')); }",
  ]) {
    test('accepts locally bound label factory: $body', () {
      final workspace = FixtureWorkspace({
        'files': {
          'lib/view.dart': {
            'role': 'view',
            'source':
                "import 'package:flutter/material.dart';\nimport 'package:flutter/material.dart' as material;\n$body",
          },
        },
      });
      addTearDown(workspace.dispose);
      expect(rule.check(workspace.snapshot), isEmpty);
    });
  }
  test('accepts shared actions, navigation, viewers and unrelated names', () {
    final workspace = FixtureWorkspace({
      'files': {
        'lib/view.dart': {
          'role': 'view',
          'source': """
import 'package:flutter/material.dart' hide TextButton;
class TextButton { TextButton({Object? child}); }
Object build() => [
  TextButton(child: Text('Save')),
  FilledButton(child: Text('Next')),
  IconButton(tooltip: 'Close', icon: Icon(Icons.close)),
  StudioFormActions(confirmLabel: 'Save changes'),
];
""",
        },
      },
    });
    addTearDown(workspace.dispose);
    expect(rule.check(workspace.snapshot), isEmpty);
  });
  test(
    'CLI rejects the actual bad fixture and accepts repaired input',
    () async {
      final workspace = FixtureWorkspace({
        'files': {
          'lib/view.dart': {
            'role': 'view',
            'source': """
import 'package:flutter/material.dart';
Object build() => FilledButton(child: Text('Save'));
""",
          },
        },
      });
      addTearDown(workspace.dispose);
      final directory = await Directory.systemTemp.createTemp('wing-form-cli-');
      addTearDown(() => directory.delete(recursive: true));
      final dart = '${dartSdkPath(Directory.current.path)}/bin/dart';
      final kernel = '${directory.path}/rule.dill';
      // Compile the actual entry point once; each verdict still uses a fresh VM.
      final compiled = await Process.run(dart, [
        'compile',
        'kernel',
        'tools/architecture/rules/form_confirmation_actions.dart',
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
      final report =
          jsonDecode(rejected.stdout as String) as Map<String, dynamic>;
      expect((report['findings'] as List).single['id'], rule.id);
      File('${workspace.directory.path}/lib/view.dart').writeAsStringSync(
        'Object build() => StudioFormActions(confirmLabel: "Save");',
      );
      final accepted = await run();
      expect(
        accepted.exitCode,
        0,
        reason: '${accepted.stdout}\n${accepted.stderr}',
      );
    },
  );
}
