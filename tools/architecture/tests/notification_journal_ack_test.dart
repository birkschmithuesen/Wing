import 'dart:convert';
import 'dart:io';

import '../dart_sdk.dart';
import '../proof_process.dart';
import '../rules/notification_journal_ack.dart' as rule;

const prefsImport =
    "import 'package:shared_preferences/shared_preferences.dart';";
String page(
  String body, {
  String imports = prefsImport,
  String type = 'SharedPreferences',
}) =>
    '$imports\nclass ChatNotificationCoordinator {\nfinal $type preferences;\nChatNotificationCoordinator(this.preferences);\n$body\n}';

class Case {
  const Case(
    this.name,
    this.source, {
    this.extra = const {},
    this.packages = const {},
    this.status = 0,
    this.line = 5,
    this.file = rule.owner,
    this.cli = false,
  });
  final String name, source, file;
  final Map<String, String> extra, packages;
  final int status, line;
  final bool cli;
}

class Workspace {
  final root = Directory.systemTemp.createTempSync('wing-journal-ack-');

  void load(Case c) {
    // Reuse dependency summaries, never a previous fixture's authored sources.
    // Each rule invocation still creates and disposes its own analysis context.
    final sourcesRoot = Directory('${root.path}/lib');
    if (sourcesRoot.existsSync()) sourcesRoot.deleteSync(recursive: true);
    final sources = {rule.owner: c.source, ...c.extra};
    final roles = <String, Object>{};
    for (final e in sources.entries) {
      final file = File('${root.path}/${e.key}');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(e.value);
      roles[e.key] = {
        'role': 'application',
        'feature': 'notifications',
        'library': e.key,
      };
    }
    File(rolePath).writeAsStringSync(jsonEncode({'schema': 1, 'files': roles}));
    final original = File('.dart_tool/package_config.json');
    final data = jsonDecode(original.readAsStringSync()) as Map;
    final config = File('${root.path}/.dart_tool/package_config.json');
    config.parent.createSync();
    config.writeAsStringSync(
      jsonEncode({
        ...data,
        'packages': [
          for (final p in (data['packages'] as List).cast<Map>())
            {
              ...p,
              'rootUri': p['name'] == 'wing'
                  ? root.uri.toString()
                  : original.uri.resolve(p['rootUri'] as String).toString(),
            },
          for (final p in c.packages.entries)
            {'name': p.key, 'rootUri': p.value, 'packageUri': ''},
        ],
      }),
    );
  }

  String get rolePath => '${root.path}/roles.json';
}

void require(bool value, String why) {
  if (!value) throw StateError(why);
}

Future<void> main(List<String> args) =>
    withProofProcesses(() => _proofMain(args));

Future<void> _proofMain(List<String> args) async {
  final sdk = dartSdkPath(Directory.current.path);
  if (Platform.environment['WING_ACK_FIXTURE_CHILD'] != '1') {
    final scratch = Directory.systemTemp.createTempSync(
      'wing-journal-ack-suite-',
    );
    try {
      final child = await startProofProcess(
        '$sdk/bin/dart',
        [
          'run',
          File(
            'tools/architecture/tests/notification_journal_ack_test.dart',
          ).absolute.path,
          ...args,
        ],
        environment: {'TMPDIR': scratch.path, 'WING_ACK_FIXTURE_CHILD': '1'},
      );
      try {
        await Future.wait([
          stdout.addStream(child.stdout),
          stderr.addStream(child.stderr),
        ]);
        exitCode = await child.exitCode;
      } finally {
        child.kill();
        await child.exitCode;
      }
    } finally {
      scratch.deleteSync(recursive: true);
    }
    return;
  }
  String? compiled;
  if (args.isNotEmpty) {
    require(
      args.length == 2 &&
          args.first == '--compiled' &&
          File(args.last).existsSync(),
      'Use --compiled EXISTING_BINARY',
    );
    compiled = File(args.last).absolute.path;
  }
  final cases = [
    Case(
      'original void future arrow',
      page("Future<void> write() => preferences.setString('journal','value');"),
      status: 1,
      cli: true,
    ),
    Case(
      'void arrow',
      page("void write() => preferences.setString('journal','value');"),
      status: 1,
    ),
    Case(
      'bare statement',
      page(
        "Future<void> write() async { preferences.setString('journal','value'); }",
      ),
      status: 1,
    ),
    Case(
      'awaited statement',
      page(
        "Future<void> write() async { await preferences.setString('journal','value'); }",
      ),
      status: 1,
    ),
    Case(
      'void future return',
      page(
        "Future<void> write() { return preferences.setString('journal','value'); }",
      ),
      status: 1,
    ),
    Case(
      'awaited return',
      page(
        "Future<void> write() async { return await preferences.setString('journal','value'); }",
      ),
      status: 2,
    ),
    Case(
      'parenthesized',
      page(
        "Future<void> write() => (preferences.setString('journal','value'));",
      ),
      status: 1,
    ),
    Case(
      'erased cast',
      page(
        "Future<void> write() => preferences.setString('journal','value') as Future<void>;",
      ),
      status: 1,
    ),
    Case(
      'prefixed import',
      page(
        "Future<void> write() => preferences.setString('journal','value');",
        imports:
            "import 'package:shared_preferences/shared_preferences.dart' as p;",
        type: 'p.SharedPreferences',
      ),
      status: 1,
    ),
    Case(
      'type alias',
      page(
        "Future<void> write() => preferences.setString('journal','value');",
        imports: "$prefsImport typedef Store = SharedPreferences;",
        type: 'Store',
      ),
      status: 1,
    ),
    Case(
      'receiver alias',
      page(
        "Future<void> write() { final store=preferences; return store.setString('journal','value'); }",
      ),
      status: 1,
    ),
    Case(
      'local tearoff',
      page(
        "Future<void> write() { final writer=preferences.setString; return writer('journal','value'); }",
      ),
      status: 1,
    ),
    Case(
      'tearoff call',
      page(
        "Future<void> write() { final writer=preferences.setString; return writer.call('journal','value'); }",
      ),
      status: 1,
    ),
    Case(
      'field tearoff',
      page(
        "late final writer=preferences.setString;\nFuture<void> write() => writer('journal','value');",
      ),
      status: 1,
      line: 6,
    ),
    Case(
      'future value alias',
      page(
        "late final pending=preferences.setString('journal','value');\nFuture<void> write() async { await pending; }",
      ),
      status: 1,
      line: 6,
    ),
    Case(
      'getter tearoff',
      page(
        "Future<bool> Function(String,String) get writer => preferences.setString;\nFuture<void> write() => writer('journal','value');",
      ),
      status: 1,
      line: 6,
    ),
    Case(
      'imported field alias',
      page(
        "Future<void> write(Writes writes) => writes.writer('journal','value');",
        imports: "$prefsImport import '../../writes.dart';",
      ),
      extra: {
        'lib/writes.dart':
            "$prefsImport class Writes { Writes(this.p); final SharedPreferences p; late final writer=p.setString; }",
      },
      status: 1,
    ),
    Case(
      'barrel',
      page(
        "Future<void> write() => preferences.setString('journal','value');",
        imports: "import '../../prefs.dart';",
      ),
      extra: {
        'lib/prefs.dart':
            "export 'package:shared_preferences/shared_preferences.dart';",
      },
      status: 1,
    ),
    Case(
      'actual part',
      "$prefsImport\npart 'journal_part.dart';",
      extra: {
        'lib/core/services/journal_part.dart':
            "part of 'chat_notification_coordinator.dart';\nclass ChatNotificationCoordinator { final SharedPreferences preferences; ChatNotificationCoordinator(this.preferences); Future<void> write()=>preferences.setString('journal','value'); }",
      },
      status: 1,
      line: 2,
      file: 'lib/core/services/journal_part.dart',
    ),
    Case(
      'checked boolean',
      page(
        "Future<void> write() async { final saved=await preferences.setString('journal','value'); if(!saved) throw StateError('not saved'); }",
      ),
      cli: true,
    ),
    Case(
      'preserved future bool',
      page("Future<bool> write()=>preferences.setString('journal','value');"),
    ),
    Case(
      'preserved awaited bool',
      page(
        "Future<bool> write() async { return await preferences.setString('journal','value'); }",
      ),
    ),
    Case(
      'stored future checked',
      page(
        "Future<void> write() async { final pending=preferences.setString('journal','value'); if(!await pending) throw StateError('not saved'); }",
      ),
    ),
    Case(
      'stored bool exposed',
      page(
        "Future<bool> write() async { final saved=await preferences.setString('journal','value'); return saved; }",
      ),
    ),
    Case(
      'unrelated homonym',
      "${page("Future<void> write(Fake p)=>p.setString('journal','value');")}\nclass Fake { Future<bool> setString(String a,String b) async=>true; }",
      cli: true,
    ),
    Case(
      'shadowed alias',
      "${page("Future<void> write(Fake p) { final writer=p.setString; return writer('journal','value'); }")}\nclass Fake { Future<bool> setString(String a,String b) async=>true; }",
    ),
    Case(
      'colliding alias declarations',
      "${page("Future<void> write() { final writer=preferences.setString; return writer('journal','value'); }")}\nclass Elsewhere { final writer=1; }",
      status: 1,
    ),
    Case(
      'dynamic receiver',
      page("Future<void> write(dynamic p)=>p.setString('journal','value');"),
      status: 2,
      cli: true,
    ),
    Case(
      'mutable tearoff alias',
      page(
        "Future<void> write() { var writer=preferences.setString; return writer('journal','value'); }",
      ),
      status: 2,
    ),
    Case(
      'mutable field alias',
      page(
        "late var writer=preferences.setString;\nFuture<void> write()=>writer('journal','value');",
      ),
      status: 2,
    ),
    Case(
      'non-ACK map operations',
      page(
        "final entries=<String,String>{};\nvoid clearEntries() { entries.clear(); entries.remove('entry'); }",
      ),
    ),
    Case('syntax', "class ChatNotificationCoordinator {", status: 2),
    Case(
      'missing namespace',
      page('String read()=>\'safe\';', imports: "import '../../missing.dart';"),
      status: 2,
    ),
    Case(
      'missing sdk namespace',
      page("String read()=>'safe';", imports: "import 'dart:wing_missing';"),
      status: 2,
    ),
    Case(
      'conditional namespace',
      page(
        "String read()=>'safe';",
        imports: "import '../../a.dart' if (dart.library.io) '../../b.dart';",
      ),
      extra: {'lib/a.dart': 'class A {}', 'lib/b.dart': 'class B {}'},
      status: 2,
    ),
    Case('ordinary noncandidate SDK error', page('String read()=>12;')),
    Case(
      'actual missing package part',
      page(
        "String read()=>cached;",
        imports: "import 'package:ack_bridge/bridge.dart';",
        type: 'Object',
      ),
      extra: {
        'lib/package/bridge.dart': "library bridge; part '../piece.dart';",
        'lib/piece.dart': "part of bridge; String get cached=>'safe';",
      },
      packages: {'ack_bridge': '../lib/package/'},
      status: 2,
      cli: true,
    ),
    Case(
      'valid package part',
      page(
        "String read()=>cached;",
        imports: "import 'package:ack_bridge/bridge.dart';",
        type: 'Object',
      ),
      extra: {
        'lib/package/bridge.dart': "library bridge; part 'piece.dart';",
        'lib/package/piece.dart': "part of bridge; String get cached=>'safe';",
      },
      packages: {'ack_bridge': '../lib/package/'},
    ),
    Case(
      'discarded canonical cascade',
      page("void write() { preferences..setString('journal','value'); }"),
      status: 1,
      cli: true,
    ),
    Case(
      'retained cascade receiver',
      page(
        "SharedPreferences write() => preferences..setString('journal','value');",
      ),
      status: 1,
    ),
    Case(
      'unrelated cascade',
      "${page("void write(Fake p) { p..setString('journal','value'); }")}\nclass Fake { Future<bool> setString(String a,String b) async=>true; }",
    ),
    Case(
      'invalid reciprocal package part',
      page(
        'bool get harmless => value;',
        imports: "$prefsImport import 'package:ack_bridge/bridge.dart';",
      ),
      extra: {
        'lib/package/bridge.dart': "library bridge; part 'piece.dart';",
        'lib/package/piece.dart':
            "part of '../package/bridge.dart'; const value=true;",
      },
      packages: {'ack_bridge': '../lib/package/'},
      status: 2,
      cli: true,
    ),
    Case(
      'valid reciprocal package part',
      page(
        'bool get harmless => value;',
        imports: "$prefsImport import 'package:ack_bridge/bridge.dart';",
      ),
      extra: {
        'lib/package/bridge.dart': "library bridge; part 'piece.dart';",
        'lib/package/piece.dart': "part of 'bridge.dart'; const value=true;",
      },
      packages: {'ack_bridge': '../lib/package/'},
      cli: true,
    ),
    Case(
      'imported top-level getter alias',
      page(
        "Future<void> write()=>a.writer('journal','value');",
        imports: "$prefsImport import '../../writer.dart' as a;",
      ),
      extra: {
        'lib/writer.dart':
            "$prefsImport late SharedPreferences p; Future<bool> Function(String,String) get writer=>p.setString;",
      },
      status: 1,
    ),
    Case(
      'imported top-level variable alias',
      page(
        "Future<void> write()=>writer('journal','value');",
        imports: "$prefsImport import '../../writer.dart';",
      ),
      extra: {
        'lib/writer.dart':
            "$prefsImport late SharedPreferences p; late final writer=p.setString;",
      },
      status: 1,
    ),
    Case(
      'final private literal map operations',
      page(
        "final _chats=<String,int>{};\nvoid write() { _chats.clear(); _chats.remove('one'); }",
      ),
      cli: true,
    ),
    Case(
      'explicit private literal map and cascade',
      page(
        "final _chats=<String,int>{};\nvoid write() { this._chats.clear(); _chats..clear()..remove('one'); }",
      ),
    ),
    Case(
      'formal shadows literal field',
      page(
        "final _chats=<String,int>{};\nFuture<void> write(SharedPreferences _chats)=>_chats.clear();",
      ),
      status: 1,
      line: 6,
      cli: true,
    ),
    Case(
      'local shadows literal field',
      page(
        "final _chats=<String,int>{};\nFuture<void> write() { final _chats=preferences; return _chats.clear(); }",
      ),
      status: 1,
      line: 6,
    ),
    Case(
      'catch shadows literal field',
      page(
        "final _chats=<String,int>{};\nvoid write() { try { throw preferences; } catch (_chats) { _chats.clear(); } }",
      ),
      status: 2,
    ),
    Case(
      'pattern shadows literal field',
      page(
        "final _chats=<String,int>{};\nFuture<void> write() { final (_chats,)= (preferences,); return _chats.clear(); }",
      ),
      status: 1,
      line: 6,
    ),
    Case(
      'closure formal shadows literal field',
      page(
        "final _chats=<String,int>{};\nvoid write() { Future<void> inner(SharedPreferences _chats)=>_chats.clear(); inner(preferences); }",
      ),
      status: 1,
      line: 6,
    ),
    Case(
      'mutable literal field later holds preferences',
      page(
        "dynamic _chats=<String,int>{};\nFuture<void> write() { _chats=preferences; return (_chats as SharedPreferences).clear(); }",
      ),
      status: 1,
      line: 6,
    ),
    Case(
      'private field is an authority alias',
      page(
        "late final _chats=preferences;\nFuture<void> write()=>_chats.clear();",
      ),
      status: 1,
      line: 6,
    ),
    Case(
      'canonical cascade shadowing literal field',
      page(
        "final _chats=<String,int>{};\nvoid write(SharedPreferences _chats) { _chats..clear(); }",
      ),
      status: 1,
      line: 6,
    ),
    Case(
      'canonical authority inside literal map',
      page(
        "late final _chats={'one': preferences};\nFuture<void> write()=>_chats['one']!.clear();",
      ),
      status: 1,
      line: 6,
    ),
    Case(
      'part contains possible private getter override',
      "${page("final dynamic _chats=<String,int>{};\nFuture<void> write()=>_chats.clear();", imports: "$prefsImport part 'child.dart';")}\n",
      extra: {
        'lib/core/services/child.dart':
            "part of 'chat_notification_coordinator.dart'; class Child extends ChatNotificationCoordinator { Child(super.preferences); @override SharedPreferences get _chats=>preferences; }",
      },
      status: 2,
      cli: true,
    ),
    Case(
      'constructor field replacement is not literal proof',
      "$prefsImport class ChatNotificationCoordinator { final SharedPreferences preferences; final dynamic _chats={}; ChatNotificationCoordinator(this.preferences): _chats=preferences; Future<void> write()=>_chats.clear(); }",
      status: 2,
    ),
    Case(
      'invalid literal context remains SDK owned',
      page("final SharedPreferences _chats={};\nvoid write()=>_chats.clear();"),
    ),
    Case(
      'valid nearby literal shadow',
      page(
        "final _chats=<String,int>{};\nvoid write() { final _chats=<String,int>{}; _chats.clear(); }",
      ),
    ),
    Case(
      'for binding shadows literal field',
      page(
        "final _chats=<String,int>{};\nFuture<void> write() async { for(final _chats in [preferences]) { await _chats.clear(); } }",
      ),
      status: 1,
      line: 6,
    ),
    Case(
      'local alias does not impersonate a DTO member',
      "${page('Map<String,dynamic>? read(Data data)=>data.result;')}\nclass Data { Map<String,dynamic>? result; } class Helpers { Future<bool> save(SharedPreferences p) { final result=p.setString('journal','value'); return result; } }",
      cli: true,
    ),
    Case(
      'result-named canonical member alias',
      "${page('Future<void> write(Writes data)=>data.result;')}\nclass Writes { final SharedPreferences p; Writes(this.p); late final result=p.setString('journal','value'); }",
      status: 1,
      cli: true,
    ),
    Case(
      'result-named canonical prefixed getter alias',
      page(
        'Future<void> write()=>a.result;',
        imports: "$prefsImport import '../../writer.dart' as a;",
      ),
      extra: {
        'lib/writer.dart':
            "$prefsImport late SharedPreferences p; Future<bool> get result=>p.setString('journal','value');",
      },
      status: 1,
    ),
  ];
  final w = Workspace();
  for (final c in cases) {
    w.load(c);
    var actual = 0;
    try {
      final findings = await rule.check(
        w.root,
        sdkPath: sdk,
        rolesPath: w.rolePath,
      );
      if (findings.isNotEmpty) actual = 1;
      if (c.status == 1) {
        require(
          findings.length == 1,
          '${c.name}: exact diagnostic count ${findings.length}',
        );
        require(
          findings.single.id == rule.id &&
              findings.single.line == c.line &&
              findings.single.file == c.file,
          '${c.name}: actual ID/line ${findings.map((f) => f.toJson())}',
        );
      }
    } on FormatException {
      actual = 2;
    }
    require(actual == c.status, '${c.name}: expected${c.status} actual$actual');
    if (c.cli) {
      for (final command in [
        [
          '$sdk/bin/dart',
          'run',
          'tools/architecture/rules/notification_journal_ack.dart',
        ],
        if (compiled != null) [compiled],
      ]) {
        final result = await runProofProcess(command.first, [
          ...command.skip(1),
          '--root',
          w.root.path,
          '--roles',
          w.rolePath,
          '--sdk',
          sdk,
          '--json',
        ]);
        require(
          result.exitCode == c.status,
          '${c.name}: actual CLI${result.exitCode} ${result.stdout}${result.stderr}',
        );
        if (c.status == 2) {
          require(
            '${result.stderr}'.contains('[${rule.id} INPUT]'),
            '${c.name}: actual CLI input diagnostic',
          );
        } else {
          final output = jsonDecode(result.stdout as String) as Map;
          final findings = output['findings'] as List;
          require(
            output['id'] == rule.id &&
                findings.length == (c.status == 1 ? 1 : 0),
            '${c.name}: actual CLI diagnostic count',
          );
          if (c.status == 1) {
            final finding = findings.single as Map;
            require(
              finding['id'] == rule.id &&
                  finding['file'] == c.file &&
                  finding['line'] == c.line,
              '${c.name}: actual CLI diagnostic identity and location',
            );
          }
        }
      }
    }
    if (c.name == 'ordinary noncandidate SDK error' ||
        c.name == 'awaited return' ||
        c.name == 'invalid reciprocal package part' ||
        c.name == 'valid reciprocal package part' ||
        c.name == 'invalid literal context remains SDK owned') {
      final result = await runProofProcess('$sdk/bin/dart', [
        'analyze',
        '--no-fatal-warnings',
        '--format',
        'machine',
        '${w.root.path}/lib',
      ]);
      if (c.name == 'valid reciprocal package part') {
        require(result.exitCode == 0, 'actual SDK valid reciprocal control');
      } else {
        require(
          result.exitCode != 0 &&
              (c.name == 'invalid reciprocal package part'
                  ? '${result.stdout}'.contains('PART_OF_DIFFERENT_LIBRARY') ||
                        '${result.stdout}'.contains('URI_DOES_NOT_EXIST')
                  : c.name == 'invalid literal context remains SDK owned'
                  ? '${result.stdout}'.contains('INVALID_ASSIGNMENT')
                  : '${result.stdout}'.contains('RETURN_OF_INVALID_TYPE')),
          'mandatory actual SDK rejection ${c.name}: ${result.stdout}',
        );
      }
    }
    if (c.name == 'checked boolean') {
      for (final command in [
        [
          '$sdk/bin/dart',
          'run',
          'tools/architecture/rules/notification_journal_ack.dart',
        ],
        if (compiled != null) [compiled],
      ]) {
        final result = await runProofProcess(command.first, [
          ...command.skip(1),
          '--root',
          w.root.path,
          '--roles',
          w.rolePath,
          '--sdk',
          '${w.root.path}/invalid-sdk',
        ]);
        require(result.exitCode == 2, 'invalid SDK before filter');
      }
    }
    stdout.writeln('PASS ${c.name}');
  }
  stdout.writeln(
    '${cases.length} ACK cases; actual source${compiled == null ? '' : '/fresh-AOT'} CLI1/0/2, invalidSDK2 and mandatory SDK dual proof',
  );
}
