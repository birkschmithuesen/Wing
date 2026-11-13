import 'dart:convert';
import 'dart:io';

import '../model.dart';
import '../rules/saved_prompt_journal_admission.dart' as rule;
import '../proof_process.dart';

class _Case {
  const _Case(
    this.name,
    this.source,
    this.exit, {
    this.count = 0,
    this.cli = false,
    this.parts = const {},
  });
  final String name, source;
  final int exit, count;
  final bool cli;
  final Map<String, String> parts;
}

String _source({
  String regenerate = '_commandOwner(chat);',
  String edit = '_commandOwner(chat);',
  String before = '',
  String between = '',
  String after = '',
  String member = '',
  String owner = '',
  String chatType = 'ProfileChat',
  String journal = 'await _journal();',
  String stage = 'chat.reading.stageRegeneration(history, 0);',
  String accept = 'chat._runtime.acceptTurn();',
}) =>
    '''
class ProfileChat {}
class ProfileWorkspaceController $owner {
  Future<void> _journal() async {}
  Object _commandOwner(ProfileChat chat) { return chat; }
  $member
  Future<bool> _regenerate($chatType chat, Object target) async {
    $before
    try {
      $journal
      $regenerate
      $stage
      $between
      $accept
      $after
    } catch (error) {}
    await _journal();
    return true;
  }
  Future<bool> _replaceSavedPrompt(ProfileChat chat, Object selected, String text) async {
    await _journal();
    $edit
    chat.reading.stageSavedPromptEdit(history, 0, text);
    chat._runtime.acceptTurn();
    return true;
  }
}
''';

Future<void> main() => withProofProcesses(() => _proofMain());

Future<void> _proofMain() async {
  final good = _source();
  final cases = [
    _Case(
      'actual original two missing post-journal fences',
      _source(regenerate: '', edit: ''),
      1,
      count: 2,
      cli: true,
    ),
    _Case('actual repaired owner staging sequence', good, 0, cli: true),
    _Case('missing canonical owner', 'class Other {}', 2, cli: true),
    _Case('regenerate original only', _source(regenerate: ''), 1, count: 1),
    _Case('edit original only', _source(edit: ''), 1, count: 1),
    _Case(
      'pre-await fence cannot authorize later staging',
      _source(before: '_commandOwner(chat);', regenerate: ''),
      1,
      count: 1,
    ),
    _Case(
      'conditional fence cannot authorize unconditional staging',
      _source(regenerate: 'if (ready) _commandOwner(chat);'),
      1,
      count: 1,
    ),
    _Case(
      'wrong chat fence',
      _source(regenerate: '_commandOwner(other);'),
      1,
      count: 1,
    ),
    _Case(
      'other owner fence',
      _source(regenerate: 'other._commandOwner(chat);'),
      1,
      count: 1,
    ),
    _Case(
      'await introduced after fence',
      _source(regenerate: '_commandOwner(chat); await other();'),
      1,
      count: 1,
    ),
    _Case(
      'await introduced before acceptance',
      _source(between: 'await other();'),
      1,
      count: 1,
    ),
    _Case(
      'explicit this and parenthesized receivers',
      _source(
        journal: 'await (this._journal());',
        regenerate: 'this._commandOwner((chat));',
        stage: '(chat).reading.stageRegeneration(history, 0);',
        accept: '(chat)._runtime.acceptTurn();',
      ),
      0,
    ),
    _Case(
      'unrelated nested chat and helper homonyms',
      _source(
        before: 'void unrelated(ProfileChat chat) { void _commandOwner() {} }',
      ),
      0,
    ),
    _Case(
      'explicit this bypasses unrelated local helper name',
      _source(
        before: 'void _commandOwner(ProfileChat chat) {}',
        regenerate: 'this._commandOwner(chat);',
      ),
      0,
    ),
    _Case(
      'relevant helper shadow is not a fence',
      _source(before: 'void _commandOwner(ProfileChat value) {}'),
      2,
    ),
    _Case(
      'local journal shadow is not canonical persistence',
      _source(before: 'Future<void> _journal() async {}'),
      2,
    ),
    _Case(
      'same-block captured chat shadow',
      _source(before: 'final chat = other;'),
      2,
    ),
    _Case(
      'loop chat shadow',
      good
          .replaceFirst('try {', 'for (final chat in rows) { try {')
          .replaceFirst('} catch (error) {}', '} catch (error) {} }'),
      2,
    ),
    _Case(
      'catch chat shadow',
      good
          .replaceFirst('try {', 'try { other(); } catch (chat) {')
          .replaceFirst('} catch (error) {}', '}'),
      2,
    ),
    _Case(
      'pattern chat shadow unsupported',
      _source(before: 'final (chat, value) = pair;'),
      2,
    ),
    _Case(
      'type parameter shadows canonical chat',
      _source(owner: '<ProfileChat>'),
      2,
    ),
    _Case(
      'nullable captured chat unsupported',
      _source(chatType: 'ProfileChat?'),
      2,
    ),
    _Case(
      'staging helper indirection unsupported',
      _source(stage: 'stageElsewhere(chat);'),
      2,
    ),
    _Case(
      'nested stage and acceptance do not inherit authorization',
      _source(
        stage:
            'void nested() { chat.reading.stageRegeneration(history, 0); chat._runtime.acceptTurn(); }',
        accept: '',
      ),
      2,
    ),
    _Case(
      'duplicated canonical stage unsupported',
      _source(after: 'chat.reading.stageRegeneration(history, 0);'),
      2,
    ),
    _Case(
      'missing direct journal unsupported',
      _source(journal: 'persistElsewhere();'),
      2,
    ),
    _Case('ambiguous canonical owner', '$good\n$good', 2),
    _Case('malformed source', 'class ProfileWorkspaceController {', 2),
    _Case(
      'unrelated classes and top-level method homonyms',
      '$good\nclass Other { void _regenerate(ProfileChat chat) { chat.reading.stageRegeneration(history, 0); } } void _replaceSavedPrompt(ProfileChat chat) {}',
      0,
    ),
    _Case(
      'actual reciprocal no-write part',
      "part 'extra.dart';\n$good",
      0,
      parts: {
        'lib/core/services/extra.dart':
            "part of 'profile_workspace_controller.dart';\nextension OtherMethods on ProfileWorkspaceController { void unrelated() {} }",
      },
    ),
    _Case(
      'canonical owner physically declared in reciprocal part',
      "part 'extra.dart';",
      0,
      parts: {
        'lib/core/services/extra.dart':
            "part of 'profile_workspace_controller.dart';\n$good",
      },
    ),
    _Case('missing part fails input', "part 'extra.dart';\n$good", 2),
    _Case(
      'nonreciprocal part fails input',
      "part 'extra.dart';\n$good",
      2,
      parts: {'lib/core/services/extra.dart': 'class Other {}'},
    ),
    _Case(
      'orphan part fails input',
      good,
      2,
      parts: {
        'lib/core/services/extra.dart':
            "part of 'profile_workspace_controller.dart';",
      },
    ),
  ];
  final cliExits = <int>{};
  for (final fixture in cases) {
    final root = Directory.systemTemp.createTempSync(
      'wing-saved-prompt-admission-',
    );
    try {
      for (final entry in {
        rule.library: fixture.source,
        ...fixture.parts,
      }.entries) {
        final file = File('${root.path}/${entry.key}');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(entry.value);
      }
      final roles = '${root.path}/roles.json';
      File(roles).writeAsStringSync(
        jsonEncode({
          'schema': 1,
          'files': {
            rule.library: {
              'role': 'application',
              'feature': 'workspace',
              'library': rule.library,
            },
          },
        }),
      );
      var exit = 0;
      var findings = <Finding>[];
      try {
        findings = rule.check(Snapshot.load(root.path, roles));
        exit = findings.isEmpty ? 0 : 1;
      } on FormatException {
        exit = 2;
      }
      if (exit != fixture.exit || findings.length != fixture.count) {
        throw StateError(
          '${fixture.name}: expected ${fixture.exit}/${fixture.count}, got $exit/$findings',
        );
      }
      void assertFinding(Map finding) {
        final path = finding['file'] as String;
        final subject = finding['subject'] as String;
        final stage = rule.stages[subject.split('.').last];
        final text = path == rule.library
            ? fixture.source
            : fixture.parts[path]!;
        final line = text
            .substring(0, text.indexOf('chat.reading.$stage'))
            .split('\n')
            .length;
        if (finding['id'] != rule.id ||
            !subject.startsWith('${rule.ownerClass}.') ||
            stage == null ||
            finding['line'] != line) {
          throw StateError(
            '${fixture.name}: diagnostic identity/location $finding',
          );
        }
      }

      for (final finding in findings) {
        assertFinding(finding.toJson());
      }
      if (!fixture.cli) continue;
      if (!cliExits.add(fixture.exit)) throw StateError('Duplicate CLI proof');
      final result = await runProofProcess(proofDartExecutable, [
        'run',
        'tools/architecture/rules/saved_prompt_journal_admission.dart',
        '--root',
        root.path,
        '--roles',
        roles,
        '--json',
      ]);
      if (result.exitCode != fixture.exit) {
        throw StateError(
          '${fixture.name}: CLI ${result.exitCode}: ${result.stdout} ${result.stderr}',
        );
      }
      if (fixture.exit == 2) {
        if (!(result.stderr as String).contains('[ARCH_INPUT]')) {
          throw StateError('Missing input diagnostic');
        }
      } else {
        final problems =
            (jsonDecode(result.stdout as String) as Map)['problems'] as List;
        if (problems.length != fixture.count) {
          throw StateError('CLI count mismatch');
        }
        for (final problem in problems) {
          assertFinding(problem as Map);
        }
      }
    } finally {
      root.deleteSync(recursive: true);
    }
  }
  if (cliExits.length != 3) throw StateError('CLI exits 0/1/2 missing');
  stdout.writeln(
    '${rule.id}: ${cases.length} parsed fixtures and three CLI representatives passed',
  );
}
