import 'dart:convert';
import 'dart:io';

import '../model.dart';
import '../rules/workspace_search_owner.dart' as rule;
import '../proof_process.dart';

const part = 'lib/core/services/workspace_search_part.dart';
const legitimate = '''
class ProfileWorkspaceController {
  Object refreshActivity(dynamic resource, String id) => resource.gateway.search(id);
  Object _reconcileNotificationActivity(dynamic resource, String id) => (resource.gateway)..search(id);
  Object _pendingChatTitle(dynamic resource, String id) => ((resource).gateway).search(id);
}
''';

class _Case {
  const _Case(
    this.name,
    this.files,
    this.exit, {
    this.badFile,
    this.cli = false,
  });
  final String name;
  final Map<String, String> files;
  final int exit;
  final String? badFile;
  final bool cli;
}

const _cases = [
  _Case(
    'original searchChats plus three captured metadata seams',
    {
      rule.library: '''
class ProfileWorkspaceController {
  Object refreshActivity(dynamic resource, String id) => resource.gateway.search(id);
  Object _reconcileNotificationActivity(dynamic resource, String id) => resource.gateway.search(id);
  Object _pendingChatTitle(dynamic resource, String id) => resource.gateway.search(id);
  Object searchChats(dynamic resource, String query) => resource.gateway.search(query);
}
''',
    },
    1,
    badFile: rule.library,
    cli: true,
  ),
  _Case(
    'all three legitimate members and unrelated library homonyms',
    {
      rule.library: legitimate,
      'lib/unrelated.dart': '''
class ProfileWorkspaceController {
  Object searchChats(dynamic resource, String query) => resource.gateway.search(query);
}
''',
    },
    0,
    cli: true,
  ),
  _Case(
    'renamed duplicate implementation',
    {
      rule.library: '''
class ProfileWorkspaceController {
  Object findConversations(dynamic resource, String query) => resource.gateway.search(query);
}
''',
    },
    1,
    badFile: rule.library,
  ),
  _Case(
    'parenthesized null asserted gateway',
    {
      rule.library: '''
class ProfileWorkspaceController {
  Object find(dynamic resource) => ((resource.gateway))!.search('query');
}
''',
    },
    1,
    badFile: rule.library,
  ),
  _Case(
    'gateway cascade',
    {
      rule.library: '''
class ProfileWorkspaceController {
  Object find(dynamic resource) => (resource.gateway)..search('query');
}
''',
    },
    1,
    badFile: rule.library,
  ),
  _Case(
    'property receiver cascade',
    {
      rule.library: '''
class ProfileWorkspaceController {
  Object find(dynamic resource) => resource..gateway.search('query');
}
''',
    },
    1,
    badFile: rule.library,
  ),
  _Case('actual part includes owner metadata seams', {
    rule.library: "part 'workspace_search_part.dart';",
    part: "part of 'profile_workspace_controller.dart';\n$legitimate",
  }, 0),
  _Case(
    'bad new member in actual part',
    {
      rule.library: "part 'workspace_search_part.dart';",
      part: '''part of 'profile_workspace_controller.dart';
class ProfileWorkspaceController {
  Object anotherSearch(dynamic resource) => resource.gateway.search('query');
}
''',
    },
    1,
    badFile: part,
  ),
  _Case('named actual part', {
    rule.library: "library workspace; part 'workspace_search_part.dart';",
    part: 'part of workspace;\n$legitimate',
  }, 0),
  _Case(
    'same named member in other class is not the canonical seam',
    {
      rule.library: '''
class ProfileWorkspaceController {}
class Other {
  Object _pendingChatTitle(dynamic resource) => resource.gateway.search('query');
}
''',
    },
    1,
    badFile: rule.library,
  ),
  _Case(
    'top level seam homonym is not canonical',
    {
      rule.library: '''
class ProfileWorkspaceController {}
Object _pendingChatTitle(dynamic resource) => resource.gateway.search('query');
''',
    },
    1,
    badFile: rule.library,
  ),
  _Case(
    'named local helper cannot create another seam',
    {
      rule.library: '''
class ProfileWorkspaceController {
  Object _pendingChatTitle(dynamic resource) {
    Object find() => resource.gateway.search('query');
    return find();
  }
}
''',
    },
    1,
    badFile: rule.library,
  ),
  _Case('unrelated method search and gateway-shaped data are valid', {
    rule.library: '''
class ProfileWorkspaceController {
  Object search(dynamic service) => service.search('query');
  Object read(dynamic resource) => resource.gateway.read('sessions');
  String label() => '.gateway.search is display text';
}
''',
  }, 0),
  _Case(
    'missing canonical input',
    {'lib/other.dart': 'class Other {}'},
    2,
    cli: true,
  ),
  _Case('missing declared part', {
    rule.library:
        "part 'workspace_search_part.dart'; class ProfileWorkspaceController {}",
  }, 2),
  _Case('detached part', {
    rule.library: 'class ProfileWorkspaceController {}',
    part: "part of 'profile_workspace_controller.dart';",
  }, 2),
  _Case(
    'malformed source',
    {rule.library: 'class ProfileWorkspaceController { broken ('},
    2,
    cli: true,
  ),
];

Future<void> main() => withProofProcesses(() => _proofMain());

Future<void> _proofMain() async {
  final cliExits = <int>{};
  for (final fixture in _cases) {
    final directory = Directory.systemTemp.createTempSync('wing-search-owner-');
    try {
      final roles = <String, Object>{};
      for (final entry in fixture.files.entries) {
        final file = File('${directory.path}/${entry.key}');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(entry.value);
        roles[entry.key] = {
          'role': 'application',
          'feature': 'workspace-search',
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
        findings = rule.check(Snapshot.load(directory.path, rolePath));
        actual = findings.isEmpty ? 0 : 1;
      } on FormatException {
        actual = 2;
      }
      if (actual != fixture.exit ||
          findings.length != (fixture.exit == 1 ? 1 : 0)) {
        throw StateError(
          '${fixture.name}: expected ${fixture.exit}, got $actual $findings',
        );
      }
      if (actual == 1) {
        final finding = findings.single;
        final contents = fixture.files[fixture.badFile]!;
        // Each invalid fixture's physical bad search is its last search call.
        final offset = contents.lastIndexOf('search(');
        final line = '\n'.allMatches(contents.substring(0, offset)).length + 1;
        if (finding.id != rule.id ||
            finding.file != fixture.badFile ||
            finding.line != line ||
            finding.subject != 'gateway.search@$offset') {
          throw StateError(
            '${fixture.name}: wrong diagnostic identity/location $finding',
          );
        }
      }
      if (fixture.cli) {
        cliExits.add(actual);
        final result = await runProofProcess(proofDartExecutable, [
          'run',
          'tools/architecture/rules/workspace_search_owner.dart',
          '--root',
          directory.path,
          '--roles',
          rolePath,
          '--json',
        ]);
        if (result.exitCode != actual) {
          throw StateError(
            '${fixture.name}: CLI ${result.exitCode}: ${result.stdout} ${result.stderr}',
          );
        }
        if (actual == 2) {
          if (!(result.stderr as String).contains('[ARCH_INPUT]')) {
            throw StateError('Missing safe CLI input diagnostic');
          }
        } else {
          final problems =
              (jsonDecode(result.stdout as String) as Map)['problems'] as List;
          if (jsonEncode(problems) !=
              jsonEncode(
                findings.map((finding) => finding.toJson()).toList(),
              )) {
            throw StateError('CLI diagnostic identity/location mismatch');
          }
        }
      }
    } finally {
      directory.deleteSync(recursive: true);
    }
  }
  if (cliExits.length != 3) throw StateError('CLI exits 0/1/2 not exercised');
  stdout.writeln(
    '${rule.id}: ${_cases.length} AST fixtures; CLI exits 0/1/2 passed',
  );
}
