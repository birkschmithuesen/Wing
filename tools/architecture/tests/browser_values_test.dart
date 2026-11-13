import 'dart:convert';
import 'dart:io';

import '../model.dart';
import '../rules/browser_values.dart' as rule;
import '../proof_process.dart';

const _view = rule.library;

class _Case {
  const _Case(this.name, this.files, this.exit);
  final String name;
  final Map<String, String> files;
  final int exit;
  final int line = 1;
}

// The accepted capabilities fixtures retain the shared namespace robustness.
// These cases protect this actual completed boundary without another matrix.
const _valid =
    'final class ChatListEntry { final BrowserProject? project; ChatListEntry(this.project); } '
    'final class ChatListGroup { final List<ChatListEntry> entries; final BrowserProject? project; ChatListGroup(Iterable<ChatListEntry> entries, this.project):entries=List.unmodifiable(entries); } '
    'final class BrowserProject { final String id; BrowserProject(this.id); } '
    'final class BrowserProfileRead { final Set<String> searchMatches; BrowserProfileRead(Iterable<String> searchMatches):searchMatches=Set.unmodifiable(searchMatches); } '
    'final class BrowserReadState { final Map<String,BrowserProfileRead> profiles; BrowserReadState(Map<String,BrowserProfileRead> profiles):profiles=Map.unmodifiable(profiles); }';
final _cases = [
  _Case('original-direct', {
    _view: _valid.replaceFirst(
      'final BrowserProject? project;',
      'final Map<String,dynamic>? project;',
    ),
  }, 1),
  _Case('typed-owner', {_view: _valid}, 0),
  _Case('mutable-field', {
    _view: _valid.replaceFirst(
      'final BrowserProject? project;',
      'BrowserProject? project;',
    ),
  }, 1),
  _Case('borrowed-group-collection', {
    _view: _valid.replaceFirst(
      'entries=List.unmodifiable(entries)',
      'entries=entries',
    ),
  }, 1),
  _Case('unrelated-map', {
    _view: '$_valid class Unrelated { Map<String,dynamic> row = {}; }',
    'lib/other.dart': 'class ChatListEntry { Map<String,dynamic> row = {}; }',
  }, 0),
  _Case('missing-part', {_view: 'class Other {}'}, 2),
];

Future<void> main() => withProofProcesses(() => _proofMain());

Future<void> _proofMain() async {
  final cliExits = <int>{};
  for (final fixture in _cases) {
    final directory = Directory.systemTemp.createTempSync(
      'wing-browser-values-',
    );
    try {
      final roles = <String, Object>{};
      for (final entry in fixture.files.entries) {
        final file = File('${directory.path}/${entry.key}');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(entry.value);
        roles[entry.key] = {
          'role': entry.key == _view ? 'view' : 'utility',
          'feature': 'browser',
          'library': entry.key,
        };
      }
      final rolePath = '${directory.path}/roles.json';
      File(
        rolePath,
      ).writeAsStringSync(jsonEncode({'schema': 1, 'files': roles}));
      var actual = 0;
      var findings = <Finding>[];
      try {
        final snapshot = Snapshot.load(directory.path, rolePath);
        findings = rule.check(snapshot);
        actual = findings.isEmpty ? 0 : 1;
      } on FormatException {
        actual = 2;
      }
      if (actual != fixture.exit ||
          (actual == 1 &&
              (findings.length != 1 ||
                  findings.single.id != rule.id ||
                  findings.single.file != _view ||
                  findings.single.line != fixture.line))) {
        throw StateError(
          '${fixture.name}: expected ${fixture.exit}, got $actual / $findings',
        );
      }
      if ({
        'original-direct',
        'typed-owner',
        'missing-part',
      }.contains(fixture.name)) {
        if (!cliExits.add(fixture.exit)) {
          throw StateError('Duplicate CLI representative');
        }
        final result = await runProofProcess(proofDartExecutable, [
          'run',
          'tools/architecture/rules/browser_values.dart',
          '--root',
          directory.path,
          '--roles',
          rolePath,
          '--json',
        ]);
        if (result.exitCode != fixture.exit) {
          throw StateError(
            '${fixture.name}: CLI ${result.exitCode}: ${result.stdout} ${result.stderr}',
          );
        }
        if (fixture.exit == 2) {
          if (!(result.stderr as String).contains('[ARCH_INPUT]')) {
            throw StateError('Missing CLI input diagnostic');
          }
        } else {
          final json = jsonDecode(result.stdout as String) as Map;
          final diagnostics = json['problems'] as List;
          if (fixture.exit == 0
              ? diagnostics.isNotEmpty
              : diagnostics.length != 1 ||
                    (diagnostics.single as Map)['id'] != rule.id ||
                    (diagnostics.single as Map)['file'] != _view ||
                    (diagnostics.single as Map)['line'] != fixture.line) {
            throw StateError('CLI diagnostic identity/location mismatch');
          }
        }
      }
    } finally {
      directory.deleteSync(recursive: true);
    }
  }
  if (cliExits.length != 3) {
    throw StateError('CLI exits 1/0/2 were not all proved');
  }
  stdout.writeln(
    '${rule.id}: ${_cases.length} detector fixtures; three CLI representatives passed',
  );
}
