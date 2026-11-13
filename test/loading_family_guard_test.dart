import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../tools/architecture/dart_sdk.dart';
import '../tools/architecture/proof_process.dart';
import '../tools/architecture/rules/loading_family.dart' as loading;
import 'architecture_contract_test.dart' show FixtureWorkspace;

const declarations = '''
class StudioLoading { const StudioLoading(); const StudioLoading.page(); }
class StudioLoadingSlot { const StudioLoadingSlot(); }
class StudioWorkingIndicator { const StudioWorkingIndicator(); }
''';
FixtureWorkspace fixture(
  String expression, {
  String path = 'lib/view.dart',
  String extra = '',
  String imports =
      "import 'package:wing/core/widgets/studio_loading.dart' as studio;",
}) => FixtureWorkspace({
  'files': {
    loading.owner: {'role': 'presentation', 'source': declarations},
    path: {
      'role': 'view',
      'source': '$imports\n$extra\nObject build() => $expression;',
    },
  },
});

void main() {
  test(
    'shared form header owns its header slot but cannot put Wing in form controls',
    () {
      final accepted = fixture(
        'studio.StudioLoadingSlot()',
        path: 'lib/core/widgets/studio_form_actions.dart',
      );
      addTearDown(accepted.dispose);
      expect(loading.check(accepted.snapshot), isEmpty);
      final rejected = fixture(
        'studio.StudioLoading()',
        path: 'lib/core/widgets/studio_form_actions.dart',
      );
      addTearDown(rejected.dispose);
      expect(loading.check(rejected.snapshot).single.id, loading.id);
    },
  );

  for (final expression in [
    'studio.StudioLoading()',
    'const studio.StudioLoading()',
    'studio.StudioLoading.new',
    'studio.StudioLoading.page()',
    'studio.StudioLoadingSlot()',
    'studio.StudioWorkingIndicator()',
  ]) {
    test('rejects component branded reference $expression', () {
      final workspace = fixture(expression);
      addTearDown(workspace.dispose);
      final findings = loading.check(workspace.snapshot);
      expect(findings, isNotEmpty);
      expect(
        findings.every(
          (f) => f.id == loading.id && f.file == 'lib/view.dart' && f.line == 3,
        ),
        isTrue,
      );
    });
  }
  test('allows original native component loading', () {
    final workspace = fixture(
      'CircularProgressIndicator()',
      imports: '',
      extra: '''
Object CircularProgressIndicator() => 0;
Object examples() => [LinearProgressIndicator(), CupertinoActivityIndicator(), RefreshIndicator(), RefreshIndicator.noSpinner()];
''',
    );
    addTearDown(workspace.dispose);
    expect(loading.check(workspace.snapshot), isEmpty);
  });
  test('accepts an unrelated same-name widget', () {
    final workspace = fixture(
      'StudioLoading()',
      imports: '',
      extra: 'class StudioLoading {}',
    );
    addTearDown(workspace.dispose);
    expect(loading.check(workspace.snapshot), isEmpty);
  });
  for (final body in [
    'Object build(Function StudioLoading) => StudioLoading();',
    'Object build(dynamic studio) => studio.StudioLoading();',
    'Object build(dynamic StudioLoading) => StudioLoading.page();',
    'Object build() { Object StudioLoading() => 0; return StudioLoading(); }',
  ]) {
    test('accepts locally bound loading name: $body', () {
      final workspace = FixtureWorkspace({
        'files': {
          loading.owner: {'role': 'presentation', 'source': declarations},
          'lib/view.dart': {
            'role': 'view',
            'source':
                "import 'package:wing/core/widgets/studio_loading.dart';\nimport 'package:wing/core/widgets/studio_loading.dart' as studio;\n$body",
          },
        },
      });
      addTearDown(workspace.dispose);
      expect(loading.check(workspace.snapshot), isEmpty);
    });
  }
  test('rejects constructor aliases and tearoffs', () {
    final workspace = fixture(
      'Pulse()',
      extra:
          'typedef Pulse = studio.StudioLoading;\nfinal create = studio.StudioLoading.new;',
    );
    addTearDown(workspace.dispose);
    expect(
      loading.check(workspace.snapshot).map((f) => f.line),
      containsAll([2, 3, 4]),
    );
  });
  test('rejects reexports and conditional imports', () {
    final workspace = FixtureWorkspace({
      'files': {
        loading.owner: {'role': 'presentation', 'source': declarations},
        'lib/barrel.dart': {
          'role': 'view',
          'source':
              "export 'package:wing/core/widgets/studio_loading.dart' show StudioLoading;",
        },
        'lib/view.dart': {
          'role': 'view',
          'source':
              "import 'barrel.dart' if (dart.library.io) 'barrel.dart' as ui;\nObject build() => ui.StudioLoading();",
        },
      },
    });
    addTearDown(workspace.dispose);
    expect(
      loading.check(workspace.snapshot).any((f) => f.file == 'lib/view.dart'),
      isTrue,
    );
  });
  for (final path in loading.workStatusOwners) {
    test('conversation owner $path', () {
      final workspace = fixture('studio.StudioWorkingIndicator()', path: path);
      addTearDown(workspace.dispose);
      expect(loading.check(workspace.snapshot), isEmpty);
    });
  }
  for (final path in loading.headerOwners) {
    test('header owner $path', () {
      final workspace = fixture('studio.StudioLoadingSlot()', path: path);
      addTearDown(workspace.dispose);
      expect(loading.check(workspace.snapshot), isEmpty);
    });
  }
  test('desktop border remains scoped to Chats', () {
    final workspace = FixtureWorkspace({
      'files': {
        'lib/core/widgets/chat_working_border.dart': {
          'role': 'view',
          'source': 'class ChatWorkingBorder {}',
        },
        loading.desktopChatRows: {
          'role': 'view',
          'source':
              "import '../widgets/chat_working_border.dart'; Object build()=>ChatWorkingBorder();",
        },
        'lib/detail.dart': {
          'role': 'view',
          'source':
              "import 'core/widgets/chat_working_border.dart' as ui; Object build()=>ui.ChatWorkingBorder();",
        },
      },
    });
    addTearDown(workspace.dispose);
    final findings = loading.check(workspace.snapshot);
    expect(findings, hasLength(1));
    expect(findings.single.file, 'lib/detail.dart');
  });
  for (final retired in [
    'StudioLoadingOverlay',
    'StudioActivityIndicator',
    'StudioWorkProgress',
  ]) {
    test('retired $retired remains rejected', () {
      final workspace = fixture('studio.$retired()');
      addTearDown(workspace.dispose);
      expect(loading.check(workspace.snapshot), isNotEmpty);
    });
  }
  for (final expression in [
    'StudioLoading.page()',
    'const StudioLoading.page()',
    'StudioLoading.page',
  ]) {
    test('retired page factory is rejected inside owner: $expression', () {
      final workspace = FixtureWorkspace({
        'files': {
          loading.owner: {
            'role': 'presentation',
            'source': '$declarations\nObject bad() => $expression;',
          },
        },
      });
      addTearDown(workspace.dispose);
      expect(loading.check(workspace.snapshot), isNotEmpty);
    });
  }
  test('real CLI accepts native component feedback', () async {
    final workspace = fixture(
      'CircularProgressIndicator()',
      imports: "import 'package:flutter/material.dart';",
    );
    addTearDown(workspace.dispose);
    final result = await runProofProcess(
      '${dartSdkPath(Directory.current.path)}/bin/dart',
      [
        'run',
        'tools/architecture/rules/loading_family.dart',
        '--root',
        workspace.directory.path,
        '--roles',
        workspace.rolesPath,
        '--strict',
        '--json',
      ],
    );
    expect(result.exitCode, 0, reason: '${result.stdout} ${result.stderr}');
    expect((jsonDecode(result.stdout as String) as Map)['findings'], isEmpty);
  });
  test('real CLI preserves rule, source, line and nonzero exit', () async {
    final workspace = fixture('studio.StudioLoadingSlot()');
    addTearDown(workspace.dispose);
    final dart = '${dartSdkPath(Directory.current.path)}/bin/dart';
    final result = await runProofProcess(dart, [
      'run',
      'tools/architecture/rules/loading_family.dart',
      '--root',
      workspace.directory.path,
      '--roles',
      workspace.rolesPath,
      '--strict',
      '--json',
    ]);
    expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
    final report = jsonDecode(result.stdout as String) as Map;
    final diagnostic = (report['findings'] as List).single as Map;
    expect(diagnostic['id'], loading.id);
    expect(diagnostic['file'], 'lib/view.dart');
    expect(diagnostic['line'], 3);
  });
}
