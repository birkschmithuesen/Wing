import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/model.dart';
import '../tools/architecture/rules/intelligence_read_admission.dart' as rule;

const _good = '''
class ProfileWorkspaceController {
  Future<void> loadIntelligence(chat) async {
    final runtime = chat.runtime;
    void requireCurrentRead() {
      if (chat.runtime != runtime) throw StateError('Stale');
    }
    requireCurrentRead();
    final results = await gateway.read();
    requireCurrentRead();
    chat.reasoning = results;
    changed();
  }
}
''';
const _original = '''
class ProfileWorkspaceController {
  Future<void> loadIntelligence(chat) async {
    final results = await gateway.read();
    chat.reasoning = results;
    changed();
  }
}
''';

Directory _fixture(Map<String, String> sources) {
  final directory = Directory.systemTemp.createTempSync(
    'wing-intelligence-guard-',
  );
  for (final entry in sources.entries) {
    final file = File('${directory.path}/${entry.key}');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(entry.value);
  }
  File('${directory.path}/roles.json').writeAsStringSync(
    jsonEncode({
      'schema': 1,
      'files': {
        for (final path in sources.keys)
          path: {
            'role': 'application',
            'feature': 'model-selection',
            'library': path.endsWith('_part.dart') ? rule.owner : path,
          },
      },
    }),
  );
  return directory;
}

void main() {
  final invalid = {
    'original unguarded result': _original,
    'missing post-read admission': _good.replaceFirst(
      '    requireCurrentRead();\n    chat.reasoning',
      '    chat.reasoning',
    ),
    'admission after publication': _good.replaceFirst(
      '    requireCurrentRead();\n    chat.reasoning = results;',
      '    chat.reasoning = results;\n    requireCurrentRead();',
    ),
    'uninvoked callback cannot admit': _good.replaceFirst(
      '    requireCurrentRead();\n    chat.reasoning',
      '    () { requireCurrentRead(); };\n    chat.reasoning',
    ),
    'asynchronous checker cannot admit': _good.replaceFirst(
      'void requireCurrentRead() {',
      'Future<void> requireCurrentRead() async {',
    ),
    'missing initial admission': _good.replaceFirst(
      '    requireCurrentRead();\n    final results',
      '    final results',
    ),
    'assignment publishes before post-read admission': _good.replaceFirst(
      'final results = await gateway.read();',
      'chat.reasoning = await gateway.read();',
    ),
    'wrapped await processes before admission': _good.replaceFirst(
      'final results = await gateway.read();',
      'final results = normalize(await gateway.read());',
    ),
    'grouped declarations process before admission': _good.replaceFirst(
      'final results = await gateway.read();',
      'final results = await gateway.read(), other = chat.reasoning;',
    ),
    'initial admission must immediately precede read': _good.replaceFirst(
      '    requireCurrentRead();\n    final results',
      '    requireCurrentRead();\n    log();\n    final results',
    ),
  };
  for (final entry in invalid.entries) {
    test(entry.key, () {
      final directory = _fixture({rule.owner: entry.value});
      addTearDown(() => directory.deleteSync(recursive: true));
      final findings = rule.check(
        Snapshot.load(directory.path, '${directory.path}/roles.json'),
      );
      expect(findings, hasLength(1));
      expect(findings.single.id, rule.id);
      expect(findings.single.file, rule.owner);
      expect(findings.single.line, greaterThan(0));
    });
  }
  test('captured direct admission and unrelated homonyms are valid', () {
    final directory = _fixture({
      rule.owner: _good,
      'lib/other.dart': _original,
    });
    addTearDown(() => directory.deleteSync(recursive: true));
    expect(
      rule.check(Snapshot.load(directory.path, '${directory.path}/roles.json')),
      isEmpty,
    );
  });
  test('actual library parts retain the boundary', () {
    const part = 'lib/core/services/intelligence_part.dart';
    final directory = _fixture({
      rule.owner: "part 'intelligence_part.dart';",
      part: "part of 'profile_workspace_controller.dart';\n$_good",
    });
    addTearDown(() => directory.deleteSync(recursive: true));
    expect(
      rule.check(Snapshot.load(directory.path, '${directory.path}/roles.json')),
      isEmpty,
    );
  });
  test(
    'independent CI command propagates invalid, valid and input exits',
    () async {
      for (final entry in {
        1: _original,
        0: _good,
        2: 'class ProfileWorkspaceController {}',
      }.entries) {
        final directory = _fixture({rule.owner: entry.value});
        try {
          final result = await Process.run('dart', [
            'run',
            'tools/architecture/rules/intelligence_read_admission.dart',
            '--root',
            directory.path,
            '--roles',
            '${directory.path}/roles.json',
            '--strict',
            '--json',
          ]);
          expect(
            result.exitCode,
            entry.key,
            reason: '${result.stdout}\n${result.stderr}',
          );
          if (entry.key == 1) {
            final output = jsonDecode(result.stdout as String) as Map;
            expect((output['problems'] as List).single['id'], rule.id);
          }
        } finally {
          directory.deleteSync(recursive: true);
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
