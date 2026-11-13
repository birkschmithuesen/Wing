import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:analyzer/dart/analysis/results.dart';

import '../tools/architecture/check_all.dart';
import '../tools/architecture/cli.dart';
import '../tools/architecture/dart_sdk.dart';
import '../tools/architecture/model.dart';
import '../tools/architecture/semantic_context.dart';
import '../tools/architecture/rules/domain_dependencies.dart' as domain;
import '../tools/architecture/rules/activity_density.dart' as density;

/// Fixture source is tracked as JSON data, then materialized outside ordinary
/// analyzer/test discovery. The guard parses it through its public input path.
class FixtureWorkspace {
  FixtureWorkspace(Map<String, dynamic> fixture) {
    final entries = fixture['files'] as Map<String, dynamic>;
    final roleEntries = <String, dynamic>{};
    for (final entry in entries.entries) {
      final value = entry.value as Map<String, dynamic>;
      final file = File('${directory.path}/${entry.key}');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(value['source'] as String);
      if (value['classified'] != false) {
        roleEntries[entry.key] = {
          'role': value['role'],
          'feature': 'fixture',
          'library': value['library'] ?? entry.key,
        };
      }
    }
    roleEntries.addAll((fixture['extraRoles'] as Map<String, dynamic>?) ?? {});
    for (final name in ['pubspec.yaml', 'pubspec.lock']) {
      File(name).copySync('${directory.path}/$name');
    }
    final retired = File(
      '${directory.path}/tools/architecture/dead_code/retired.json',
    );
    retired.parent.createSync(recursive: true);
    retired.writeAsStringSync(jsonEncode({'schema': 2, 'entries': []}));
    File(
      rolesPath,
    ).writeAsStringSync(jsonEncode({'schema': 1, 'files': roleEntries}));
    writeBaseline([]);
  }
  final directory = Directory.systemTemp.createTempSync(
    'wing-architecture-contract-',
  );
  String get rolesPath => '${directory.path}/roles.json';
  String get baselinePath => '${directory.path}/baseline.json';
  Snapshot get snapshot => Snapshot.load(directory.path, rolesPath);
  void writeBaseline(List<Map<String, Object>> entries, {String? path}) => File(
    path ?? baselinePath,
  ).writeAsStringSync(jsonEncode({'schema': 1, 'entries': entries}));
  void dispose() => directory.deleteSync(recursive: true);
}

Map<String, Object> baselineEntry(Finding finding) => {
  'id': finding.id,
  'file': finding.file,
  'subject': finding.subject,
  'reason': 'Characterized pre-migration fixture violation',
};

void main() {
  final fixtures =
      (jsonDecode(
                File(
                  'tools/architecture/fixtures/contracts.fixture.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>)['cases']
          as List;
  for (final fixture in fixtures.cast<Map<String, dynamic>>()) {
    test(fixture['name'] as String, () async {
      final workspace = FixtureWorkspace(fixture);
      addTearDown(workspace.dispose);
      final id = fixture['rule'] as String;
      final findings = await allRules[id]!(workspace.snapshot);
      expect(findings.isNotEmpty, fixture['expect']);
      for (final finding in findings) {
        expect(finding.id, id);
        expect(finding.file, startsWith('lib/'));
        expect(finding.line, greaterThan(0));
      }
    });
  }

  FixtureWorkspace domainFixture(String source) => FixtureWorkspace({
    'files': {
      'lib/value.dart': {'role': 'domain', 'source': source},
    },
  });

  test('baseline cannot hide a second occurrence of an existing violation', () {
    final workspace = domainFixture("import 'dart:io'; class Value {}");
    addTearDown(workspace.dispose);
    final original = domain.check(workspace.snapshot).single;
    workspace.writeBaseline([baselineEntry(original)]);
    File(
      '${workspace.directory.path}/lib/value.dart',
    ).writeAsStringSync("import 'dart:io'; import 'dart:io'; class Value {}");
    final findings = domain.check(workspace.snapshot);
    expect(findings, hasLength(2));
    final problems = applyBaseline(findings, workspace.baselinePath, {
      domain.id,
    });
    expect(problems, hasLength(1));
    expect(problems.single.subject, 'import:dart:io#2');
  });

  test('baseline identifiers survive formatting and reject stale entries', () {
    final workspace = domainFixture("import 'dart:io'; class Value {}");
    addTearDown(workspace.dispose);
    workspace.writeBaseline(
      domain.check(workspace.snapshot).map(baselineEntry).toList(),
    );
    final source = File('${workspace.directory.path}/lib/value.dart');
    source.writeAsStringSync("\n\nimport 'dart:io';\nclass Value {}\n");
    expect(
      applyBaseline(domain.check(workspace.snapshot), workspace.baselinePath, {
        domain.id,
      }),
      isEmpty,
    );
    source.writeAsStringSync('class Value {}');
    expect(
      applyBaseline(domain.check(workspace.snapshot), workspace.baselinePath, {
        domain.id,
      }).single.id,
      'ARCH_BASELINE',
    );
  });

  test('baseline reference permits shrinkage and rejects added exemptions', () {
    final workspace = domainFixture(
      "import 'dart:io'; import 'dart:isolate'; class Value {}",
    );
    addTearDown(workspace.dispose);
    final findings = domain.check(workspace.snapshot);
    final reference = '${workspace.directory.path}/previous.json';
    workspace.writeBaseline([baselineEntry(findings.first)], path: reference);
    workspace.writeBaseline(findings.map(baselineEntry).toList());
    final problems = applyBaseline(findings, workspace.baselinePath, {
      domain.id,
    }, reference: reference);
    expect(problems.single.id, 'ARCH_BASELINE');
    workspace.writeBaseline(
      findings.map(baselineEntry).toList(),
      path: reference,
    );
    workspace.writeBaseline([baselineEntry(findings.first)]);
    expect(
      applyBaseline(
        [findings.first],
        workspace.baselinePath,
        {domain.id},
        reference: reference,
      ),
      isEmpty,
    );
  });

  test('baseline rejects malformed duplicate exemption data', () {
    final workspace = domainFixture("import 'dart:io'; class Value {}");
    addTearDown(workspace.dispose);
    final entry = baselineEntry(domain.check(workspace.snapshot).single);
    workspace.writeBaseline([entry, entry]);
    expect(() => readBaseline(workspace.baselinePath), throwsFormatException);
  });

  test('shared semantic summaries refresh after source changes', () async {
    final directory = Directory.systemTemp.createTempSync(
      'wing-semantic-summary-freshness-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final source = File('${directory.path}/lib/value.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync('class Value { int value = 1; }\n');
    final sdk = dartSdkPath(Directory.current.path);

    Future<List<dynamic>> analyze(String cacheNamespace) async {
      final contexts = semanticContextCollection(
        root: directory.path,
        sdk: sdk,
        includedPaths: [source.path],
        cacheNamespace: cacheNamespace,
      );
      try {
        final result = await contexts
            .contextFor(source.path)
            .currentSession
            .getResolvedLibrary(source.path);
        expect(result, isA<ResolvedLibraryResult>());
        return (result as ResolvedLibraryResult).units
            .expand((unit) => unit.diagnostics)
            .toList();
      } finally {
        await contexts.dispose();
      }
    }

    await withSharedAnalysisSummaries(() async {
      final firstDiagnostics = await analyze('first-context-namespace');
      expect(
        firstDiagnostics.where(
          (diagnostic) => diagnostic.diagnosticCode.severity.name == 'ERROR',
        ),
        isEmpty,
      );

      source.writeAsStringSync("class Value { int value = 'bad'; }\n");
      final changedDiagnostics = await analyze('second-context-namespace');
      expect(
        changedDiagnostics.any(
          (diagnostic) => diagnostic.diagnosticCode.severity.name == 'ERROR',
        ),
        isTrue,
      );
    });
  });

  test(
    'actual aggregate CLI rejects bad source and accepts valid source',
    () async {
      // The aggregate needs every finite protected seam, even when this case
      // exercises a domain import violation rather than a UI violation.
      final workspace = FixtureWorkspace({
        'files': {
          'lib/value.dart': {
            'role': 'domain',
            'source': "import 'dart:io'; class Value {}",
          },
          density.rowPath: {
            'role': 'view',
            'source': 'class CompactActivityRow {}',
          },
          'lib/core/widgets/recent_conversations/recent_conversation_switcher.dart':
              {'role': 'view', 'source': 'class RecentConversationSwitcher {}'},
          'lib/core/widgets/profile_tool_call.dart': {
            'role': 'view',
            'source':
                "import 'compact_activity_row.dart'; class ProfileToolCall { Object build(Object? context) => CompactActivityRow(); }",
          },
          'lib/core/widgets/profile_saved_agents.dart': {
            'role': 'view',
            'source':
                "import 'compact_activity_row.dart'; class ProfileSavedAgents { Object _buildAgent(Object? context) => CompactActivityRow(); }",
          },
        },
      });
      addTearDown(workspace.dispose);
      final command = File('tools/architecture/check_all.dart').absolute.path;
      Future<ProcessResult> invoke() => Process.run('dart', [
        'run',
        command,
        '--root',
        workspace.directory.path,
        '--roles',
        workspace.rolesPath,
        '--baseline',
        workspace.baselinePath,
        '--json',
      ]);
      final failed = await invoke();
      expect(failed.exitCode, 1, reason: failed.stderr.toString());
      final output =
          jsonDecode(failed.stdout as String) as Map<String, dynamic>;
      expect((output['problems'] as List).single['id'], domain.id);
      File(
        '${workspace.directory.path}/lib/value.dart',
      ).writeAsStringSync('class Value {}');
      final valid = await invoke();
      expect(valid.exitCode, 0, reason: valid.stderr.toString());
      expect((jsonDecode(valid.stdout as String) as Map)['problems'], isEmpty);
      final header = File(
        '${workspace.directory.path}/lib/core/widgets/profile_tool_call.dart',
      );
      final compact = header.readAsStringSync();
      header.writeAsStringSync(
        "import 'compact_activity_row.dart'; class ProfileToolCall { Object build(Object? context) => Padding(child: CompactActivityRow()); } class Padding { Padding({Object? child}); }",
      );
      final padded = await invoke();
      expect(padded.exitCode, 1, reason: padded.stderr.toString());
      final problem =
          ((jsonDecode(padded.stdout as String) as Map)['problems'] as List)
              .single;
      expect(problem['id'], density.id);
      expect(problem['file'], 'lib/core/widgets/profile_tool_call.dart');
      header.writeAsStringSync(compact);
      final repaired = await invoke();
      expect(repaired.exitCode, 0, reason: repaired.stderr.toString());
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
