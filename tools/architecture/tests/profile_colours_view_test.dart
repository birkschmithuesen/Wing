import 'dart:convert';
import 'dart:io';

import '../dart_sdk.dart';
import '../model.dart';
import '../rules/profile_colours_view.dart' as rule;
import '../proof_process.dart';

const view = 'lib/core/widgets/profile_selector.dart';
const prefs = "import 'package:shared_preferences/shared_preferences.dart';";
const sessionImport = "import '../services/profile_colors_session.dart';";
String page(String body, {String imports = ''}) =>
    '$imports\nclass ProfileSelector { $body }';

class Case {
  const Case(
    this.name,
    this.source, {
    this.extra = const {},
    this.status = 0,
    this.line = 2,
    this.file = view,
    this.cli = false,
  });
  final String name, source, file;
  final Map<String, String> extra;
  final int status, line;
  final bool cli;
}

class Workspace {
  void load(Case c) {
    final sourcesRoot = Directory('${root.path}/lib');
    if (sourcesRoot.existsSync()) sourcesRoot.deleteSync(recursive: true);
    final sources = {
      'lib/core/widgets/chat_profile_bar.dart': 'class ChatProfileBar {}',
      'lib/core/services/app_preferences.dart':
          'class AppPreferences { AppPreferences(); Object? get(String key) => key; void reload() {} }',
      'lib/core/services/profile_color_store.dart':
          'class ProfileColorStore { ProfileColorStore(); int? read(String name) => null; }',
      'lib/core/models/profile_colors.dart':
          'enum ProfileColorChoice { automatic, blue } class ProfileColorFact { void Function()? reload; }',
      'lib/core/services/profile_colors_session.dart':
          'class ProfileColorsSession { ProfileColorsSession(); void dispose() {} void choose() {} }',
      view: c.source,
      ...c.extra,
    };
    final roles = <String, Object>{};
    for (final entry in sources.entries) {
      final file = File('${root.path}/${entry.key}');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        entry.value.replaceAll(
          '__AUTHORITY_URI__',
          File(
            '${root.path}/lib/core/services/app_preferences.dart',
          ).uri.toString(),
        ),
      );
      roles[entry.key] = {
        'role': 'view',
        'feature': 'profile-colours',
        'library': entry.key,
      };
    }
    File(rolePath).writeAsStringSync(jsonEncode({'schema': 1, 'files': roles}));
    final original = File('.dart_tool/package_config.json');
    final data = jsonDecode(original.readAsStringSync()) as Map;
    final packages = (data['packages'] as List).cast<Map>();
    final config = File('${root.path}/.dart_tool/package_config.json');
    config.parent.createSync();
    config.writeAsStringSync(
      jsonEncode({
        ...data,
        'packages': [
          for (final p in packages)
            {
              ...p,
              'rootUri': p['name'] == 'wing'
                  ? root.uri.toString()
                  : original.uri.resolve(p['rootUri'] as String).toString(),
            },
        ],
      }),
    );
  }

  final root = Directory.systemTemp.createTempSync('wing-colour-guard-');
  String get rolePath => '${root.path}/roles.json';
  Snapshot get snapshot => Snapshot.load(root.path, rolePath);
  void close() {
    // The supervisor owns this child's scratch directory. Reused summaries
    // stay live until the proof and its CLI/SDK children have finished.
    if (Platform.environment['WING_COLOUR_GUARD_FIXTURE_CHILD'] != '1') {
      root.deleteSync(recursive: true);
    }
  }
}

void require(bool value, String why) {
  if (!value) throw StateError(why);
}

Future<void> main(List<String> args) =>
    withProofProcesses(() => _proofMain(args));

Future<void> _proofMain(List<String> args) async {
  if (Platform.environment['WING_COLOUR_GUARD_FIXTURE_CHILD'] == '1') {
    await _run(args);
    return;
  }
  final scratch = Directory.systemTemp.createTempSync('wing-colour-suite-');
  try {
    final sdk = dartSdkPath(Directory.current.path);
    final child = await startProofProcess(
      '$sdk/bin/dart',
      [
        'run',
        File(
          'tools/architecture/tests/profile_colours_view_test.dart',
        ).absolute.path,
        ...args,
      ],
      environment: {
        'TMPDIR': scratch.path,
        'WING_COLOUR_GUARD_FIXTURE_CHILD': '1',
      },
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
}

Future<void> _run(List<String> args) async {
  String? compiled;
  if (args.isNotEmpty) {
    if (args.length != 2 ||
        args.first != '--compiled' ||
        !File(args.last).existsSync()) {
      throw const FormatException('Use --compiled BINARY');
    }
    compiled = File(args.last).absolute.path;
  }
  final sdk = dartSdkPath(Directory.current.path);
  final cases = [
    Case(
      'unused canonical prefs import',
      page('', imports: prefs),
      status: 1,
      line: 1,
      cli: true,
    ),
    Case(
      'direct cache read',
      page(
        "Object? read(SharedPreferences p) => p.getInt('key');",
        imports: prefs,
      ),
      status: 1,
    ),
    Case(
      'write',
      page(
        "Object? write(SharedPreferences p) => p.setInt('key',8);",
        imports: prefs,
      ),
      status: 1,
    ),
    Case(
      'prefix',
      page(
        "Object? read(s.SharedPreferences p) => p.getString('key');",
        imports:
            "import 'package:shared_preferences/shared_preferences.dart' as s;",
      ),
      status: 1,
    ),
    Case(
      'typedef capture',
      page(
        'Object? capture(P p) => p.reload;',
        imports: '$prefs typedef P = SharedPreferences;',
      ),
      status: 1,
    ),
    Case(
      'cascade',
      page(
        "Object? read(SharedPreferences p) => p..getInt('key');",
        imports: prefs,
      ),
      status: 1,
    ),
    Case(
      'barrel unused authority',
      page('', imports: "import '../../bridge.dart';"),
      extra: {
        'lib/bridge.dart':
            "export 'package:shared_preferences/shared_preferences.dart';",
      },
      status: 1,
      line: 1,
    ),
    Case(
      'combinator hiding authority',
      page('', imports: "import '../../bridge.dart' hide SharedPreferences;"),
      extra: {
        'lib/bridge.dart':
            "export 'package:shared_preferences/shared_preferences.dart' show SharedPreferences;",
      },
    ),
    Case(
      'library URI',
      page(
        '',
        imports: "import 'package:wing/core/services/app_preferences.dart';",
      ),
      status: 1,
      line: 1,
    ),
    Case(
      'inline owner',
      page(
        'Object? create() => AppPreferences();',
        imports: "import '../services/app_preferences.dart';",
      ),
      status: 1,
    ),
    Case(
      'inline route owner',
      page(
        'Object? create() => ProfileColorsSession();',
        imports: sessionImport,
      ),
      status: 1,
    ),
    Case(
      'route owner typedef',
      page(
        'Object? create() => Route();',
        imports: '$sessionImport typedef Route = ProfileColorsSession;',
      ),
      status: 1,
    ),
    Case(
      'implicit super owner',
      '$sessionImport\nclass ProfileSelector extends ProfileColorsSession {}',
      status: 1,
    ),
    Case(
      'explicit super owner',
      '$sessionImport\nclass ProfileSelector extends ProfileColorsSession { ProfileSelector(): super(); }',
      status: 1,
    ),
    Case(
      'raw owner getter',
      page(
        'final ProfileColorsSession session; ProfileSelector(this.session); Object? capture() => session.hidden;',
        imports: sessionImport,
      ),
      extra: {
        'lib/core/services/profile_colors_session.dart':
            "import 'app_preferences.dart'; class ProfileColorsSession { AppPreferences get hidden => AppPreferences(); }",
      },
      status: 1,
    ),
    Case(
      'async raw owner capture',
      page(
        'final ProfileColorsSession session; ProfileSelector(this.session); Object? capture() => session.hidden;',
        imports: sessionImport,
      ),
      extra: {
        'lib/core/services/profile_colors_session.dart':
            "import 'app_preferences.dart'; class ProfileColorsSession { Future<AppPreferences> get hidden async => AppPreferences(); }",
      },
      status: 1,
    ),
    Case(
      'helper returned authority capture',
      page(
        'Object? capture() => expose;',
        imports: "import '../../bridge.dart';",
      ),
      extra: {
        'lib/bridge.dart':
            "import 'core/services/app_preferences.dart'; AppPreferences get expose => AppPreferences();",
      },
      status: 1,
    ),
    Case(
      'file URI unused authority',
      page('', imports: "import '__AUTHORITY_URI__';"),
      status: 1,
      line: 1,
    ),
    Case(
      'constructor tearoff',
      page(
        'Object? create() => ProfileColorsSession.new;',
        imports: sessionImport,
      ),
      status: 1,
    ),
    Case(
      'mixin constructor forwarding',
      '$sessionImport\nmixin Marker {} class Helper = ProfileColorsSession with Marker; class ProfileSelector { Object? make() => Helper(); }',
      status: 1,
    ),
    Case(
      'bare inherited preferences',
      '$prefs\nabstract class Base implements SharedPreferences {} abstract class ProfileSelector extends Base { Object? capture() => reload; }',
      status: 1,
    ),
    Case(
      'inferred helper getter',
      page(
        'Object? capture() => cached;',
        imports: "import '../../bridge.dart';",
      ),
      extra: {
        'lib/bridge.dart':
            "import 'core/services/app_preferences.dart'; get cached => AppPreferences();",
      },
      status: 1,
    ),
    Case(
      'inferred helper function',
      page(
        'Object? capture() => makeCache();',
        imports: "import '../../bridge.dart';",
      ),
      extra: {
        'lib/bridge.dart':
            "import 'core/services/app_preferences.dart'; makeCache() => AppPreferences();",
      },
      status: 1,
    ),
    Case(
      'inferred helper field',
      page(
        'Object? capture(Helper helper) => helper.stash;',
        imports: "import '../../bridge.dart';",
      ),
      extra: {
        'lib/bridge.dart':
            "import 'core/services/app_preferences.dart'; class Helper { final stash = AppPreferences(); }",
      },
      status: 1,
    ),
    Case(
      'inferred helper variable',
      page(
        'Object? capture() => cache;',
        imports: "import '../../bridge.dart';",
      ),
      extra: {
        'lib/bridge.dart':
            "import 'core/services/app_preferences.dart'; final cache = AppPreferences();",
      },
      status: 1,
    ),
    Case(
      'inferred unused getter exposed',
      page('', imports: "import '../../bridge.dart';"),
      extra: {
        'lib/bridge.dart':
            "import 'core/services/app_preferences.dart'; get cached => AppPreferences();",
      },
      status: 1,
      line: 1,
    ),
    Case(
      'session spelling alias capture',
      page(
        'Object? capture(ProfileColorsSession raw) => raw;',
        imports: "import '../../bridge.dart';",
      ),
      extra: {
        'lib/bridge.dart':
            "import 'core/services/app_preferences.dart'; typedef ProfileColorsSession = AppPreferences;",
      },
      status: 1,
    ),
    Case(
      'session alias unused exposure',
      page('', imports: "import '../../bridge.dart';"),
      extra: {
        'lib/bridge.dart':
            "import 'core/services/app_preferences.dart'; typedef ProfileColorsSession = AppPreferences;",
      },
      status: 1,
      line: 1,
    ),
    Case(
      'extension raw getter',
      page(
        'Object? read(ProfileColorsSession s) => s.stash;',
        imports: "$sessionImport import '../../helper.dart';",
      ),
      extra: {
        'lib/helper.dart':
            "import 'core/services/app_preferences.dart'; import 'core/services/profile_colors_session.dart'; extension Capture on ProfileColorsSession { get stash => AppPreferences(); }",
      },
      status: 1,
    ),
    Case(
      'mixin raw getter',
      page(
        'Object? read(Helper h) => h.stash;',
        imports: "import '../../helper.dart';",
      ),
      extra: {
        'lib/helper.dart':
            "import 'core/services/app_preferences.dart'; mixin Capture { get stash => AppPreferences(); } class Helper with Capture {}",
      },
      status: 1,
    ),
    Case(
      'enum raw getter',
      page(
        'Object? read() => Helper.value.stash;',
        imports: "import '../../helper.dart';",
      ),
      extra: {
        'lib/helper.dart':
            "import 'core/services/app_preferences.dart'; enum Helper { value; get stash => AppPreferences(); }",
      },
      status: 1,
    ),
    Case(
      'extension type raw getter',
      page(
        'Object? read(Helper h) => h.stash;',
        imports: "import '../../helper.dart';",
      ),
      extra: {
        'lib/helper.dart':
            "import 'core/services/app_preferences.dart'; extension type Helper(int value) { get stash => AppPreferences(); }",
      },
      status: 1,
    ),
    Case(
      'record aggregate raw getter',
      page(
        'Object? read(Helper h) => h.stash;',
        imports: "import '../../helper.dart';",
      ),
      extra: {
        'lib/helper.dart':
            "import 'core/services/app_preferences.dart'; class Helper { (AppPreferences, int) get stash => (AppPreferences(), 1); }",
      },
      status: 1,
    ),
    Case(
      'record aggregate raw field',
      page(
        'Object? read(Helper h) => h.stash;',
        imports: "import '../../helper.dart';",
      ),
      extra: {
        'lib/helper.dart':
            "import 'core/services/app_preferences.dart'; class Helper { final (AppPreferences, int) stash = (AppPreferences(), 1); }",
      },
      status: 1,
    ),
    Case(
      'block erased helper capture',
      page('Object? read() => cached;', imports: "import '../../helper.dart';"),
      extra: {
        'lib/helper.dart': "get cached { return 'not-statically-proven'; }",
      },
      status: 2,
    ),
    Case(
      'dynamic arrow helper capture',
      page('Object? read() => cached;', imports: "import '../../helper.dart';"),
      extra: {
        'lib/helper.dart':
            "dynamic unknown() => null; get cached => unknown();",
      },
      status: 2,
    ),
    Case(
      'named record aggregate raw getter',
      page(
        'Object? read(Helper h) => h.stash;',
        imports: "import '../../helper.dart';",
      ),
      extra: {
        'lib/helper.dart':
            "import 'core/services/app_preferences.dart'; class Helper { ({AppPreferences cached}) get stash => (cached: AppPreferences()); }",
      },
      status: 1,
    ),
    Case(
      'bounded generic raw getter',
      page(
        'Object? read(Helper h) => h.stash;',
        imports: "import '../../helper.dart';",
      ),
      extra: {
        'lib/helper.dart':
            "import 'core/services/app_preferences.dart'; class Helper<T extends AppPreferences> { T get stash => throw StateError('fixture'); }",
      },
      status: 1,
    ),
    Case(
      'extension representation raw capture',
      page(
        'Object? read(Helper h) => h;',
        imports: "import '../../helper.dart';",
      ),
      extra: {
        'lib/helper.dart':
            "import 'core/services/app_preferences.dart'; extension type Helper(AppPreferences value) {}",
      },
      status: 1,
    ),
    Case(
      'unrelated extension record facts',
      page(
        'Object? read(Helper h) => h.stash;',
        imports: "import '../../helper.dart';",
      ),
      extra: {
        'lib/helper.dart':
            "extension type Helper(int value) { (int, String) get stash => (value, 'safe'); }",
      },
    ),
    Case(
      'unused Flutter services namespace',
      page(
        'Object? read(Local owner) => owner.reload();',
        imports:
            "import 'package:flutter/services.dart'; class Local { Object? reload() => null; }",
      ),
    ),
    Case(
      'valid SDK embedder namespace',
      page('Object? render() => const Color(0);', imports: "import 'dart:ui';"),
    ),
    Case(
      'session spelling extension representation',
      page(
        'Object? capture(ProfileColorsSession raw) => raw;',
        imports: "import '../../helper.dart';",
      ),
      extra: {
        'lib/helper.dart':
            "import 'core/services/app_preferences.dart'; extension type ProfileColorsSession(AppPreferences value) {}",
      },
      status: 1,
    ),
    Case(
      'raw inherited storage type',
      page(
        'Object? capture(Helper raw) => raw;',
        imports: "import '../../helper.dart';",
      ),
      extra: {
        'lib/helper.dart':
            "import 'core/services/app_preferences.dart'; class Helper extends AppPreferences {}",
      },
      status: 1,
    ),
    Case(
      'raw storage interface type',
      page(
        'Object? capture(Helper raw) => raw;',
        imports: "import '../../helper.dart';",
      ),
      extra: {
        'lib/helper.dart':
            "$prefs abstract class Helper implements SharedPreferences {}",
      },
      status: 1,
    ),
    Case(
      'harmless local session extension',
      page(
        'Object? capture(ProfileColorsSession fact) => fact;',
        imports: "import '../../helper.dart';",
      ),
      extra: {
        'lib/helper.dart': "extension type ProfileColorsSession(int value) {}",
      },
    ),
    Case(
      'unrelated inferred helper getter',
      page('Object? read() => text;', imports: "import '../../bridge.dart';"),
      extra: {'lib/bridge.dart': "get text => 'display';"},
    ),
    Case(
      'inferred helper method',
      page(
        'Object? capture(Helper helper) => helper.makeCache();',
        imports: "import '../../bridge.dart';",
      ),
      extra: {
        'lib/bridge.dart':
            "import 'core/services/app_preferences.dart'; class Helper { makeCache() => AppPreferences(); }",
      },
      status: 1,
    ),
    Case(
      'imported owner subclass',
      page(
        'Object? make() => Derived();',
        imports: "import '../../bridge.dart';",
      ),
      extra: {
        'lib/bridge.dart':
            "import 'core/services/profile_colors_session.dart'; class Derived extends ProfileColorsSession {}",
      },
      status: 1,
    ),
    Case(
      'imported mixin alias owner',
      page(
        'Object? make() => Derived();',
        imports: "import '../../bridge.dart';",
      ),
      extra: {
        'lib/bridge.dart':
            "import 'core/services/profile_colors_session.dart'; mixin Marker {} class Derived = ProfileColorsSession with Marker;",
      },
      status: 1,
    ),
    Case(
      'implicit imported owner superclass',
      "import '../../bridge.dart';\nclass ProfileSelector extends Derived {}",
      extra: {
        'lib/bridge.dart':
            "import 'core/services/profile_colors_session.dart'; class Derived extends ProfileColorsSession {}",
      },
      status: 1,
    ),
    Case(
      'orphan selected library',
      "part of missing; class ProfileSelector {}",
      status: 2,
    ),
    Case(
      'adjacent canonical key literal',
      page("String key() => 'profile_' 'color_v1_dummy';"),
      status: 1,
    ),
    Case(
      'unknown SDK namespace',
      page('', imports: "import 'dart:missing_colour_namespace';"),
      status: 2,
    ),
    Case(
      'later interpolation span',
      page("String get key => '\${''}profile_color_v1_work';"),
      status: 1,
    ),
    Case(
      'nullable raw owner getter',
      page(
        'final ProfileColorsSession session; ProfileSelector(this.session); Object? capture() => session.hidden;',
        imports: sessionImport,
      ),
      extra: {
        'lib/core/services/profile_colors_session.dart':
            "import 'app_preferences.dart'; class ProfileColorsSession { AppPreferences? get hidden => null; }",
      },
      status: 1,
    ),
    Case(
      'erased getter then storage',
      page(
        "final ProfileColorsSession session; ProfileSelector(this.session); Object? capture() => session.hidden.getInt('key');",
        imports: sessionImport,
      ),
      extra: {
        'lib/core/services/profile_colors_session.dart':
            'class ProfileColorsSession { dynamic get hidden => null; }',
      },
      status: 2,
    ),
    Case(
      'native channel',
      page(
        "Object? create() => const MethodChannel('x');",
        imports: "import 'package:flutter/services.dart' show MethodChannel;",
      ),
      status: 1,
    ),
    Case(
      'native channel alias',
      page(
        "Object? create() => Native('x');",
        imports:
            "import 'package:flutter/services.dart' show MethodChannel; typedef Native = MethodChannel;",
      ),
      status: 1,
    ),
    Case(
      'file IO',
      page(
        "Object? read() => File('x').readAsString();",
        imports: "import 'dart:io';",
      ),
      status: 1,
    ),
    Case(
      'key hashing',
      page(
        'Object? hash() => sha256.convert([1,2]);',
        imports: "import 'package:crypto/crypto.dart';",
      ),
      status: 1,
    ),
    Case(
      'key literal',
      page("String get key => 'profile_color_v1_secret_name';"),
      status: 1,
    ),
    Case(
      'interpolated key',
      page("String key(String id) => 'profile_color_v1_\${id}_work';"),
      status: 1,
    ),
    Case(
      'view export',
      page('', imports: "export '../models/profile_colors.dart';"),
      status: 1,
      line: 1,
    ),
    Case(
      'actual part',
      "library colours; part 'colour_part.dart'; class ProfileSelector {}",
      extra: {
        'lib/core/widgets/colour_part.dart':
            "part of colours;\nclass Helper { String get key => 'profile_color_v1_bad'; }",
      },
      status: 1,
      file: 'lib/core/widgets/colour_part.dart',
    ),
    Case(
      'relative part',
      "part 'colour_part.dart'; class ProfileSelector {}",
      extra: {
        'lib/core/widgets/colour_part.dart':
            "part of 'profile_selector.dart';\nclass Helper { String get key => 'profile_color_v1_bad'; }",
      },
      status: 1,
      file: 'lib/core/widgets/colour_part.dart',
    ),
    Case(
      'conditional export unused',
      page('', imports: "import '../../bridge.dart';"),
      extra: {
        'lib/bridge.dart': "export 'a.dart' if (dart.library.io) 'b.dart';",
        'lib/a.dart': '',
        'lib/b.dart': '',
      },
      status: 2,
    ),
    Case(
      'missing namespace',
      page('', imports: "import 'missing.dart';"),
      status: 2,
    ),
    Case(
      'duplicate owner',
      "part 'colour_part.dart'; class ProfileSelector {}",
      extra: {
        'lib/other.dart': "part 'core/widgets/colour_part.dart';",
        'lib/core/widgets/colour_part.dart': "part of 'profile_selector.dart';",
      },
      status: 2,
    ),
    Case('invalid scope', 'class Other {}', status: 2),
    Case('syntax input', 'class ProfileSelector {', status: 2, cli: true),
    Case(
      'typed injected owner commands',
      page(
        'final ProfileColorsSession session; ProfileSelector(this.session); void close() => session.dispose(); void save() => session.choose();',
        imports: sessionImport,
      ),
      cli: true,
    ),
    Case(
      'owner reload callback',
      page('void reload() {} void save() => reload();'),
    ),
    Case(
      'local same-name owner',
      page(
        'Object? create() => ProfileColorsSession();',
        imports: 'class ProfileColorsSession {}',
      ),
    ),
    Case(
      'local same-name prefs',
      page(
        "Object? read(SharedPreferences p) => p.getInt('x');",
        imports: 'class SharedPreferences { int getInt(String key) => 1; }',
      ),
    ),
    Case(
      'local native homonym',
      page(
        "Object? create() => const MethodChannel('x');",
        imports: 'class MethodChannel { const MethodChannel(String name); }',
      ),
    ),
    Case(
      'passive DTO callback',
      page(
        'void reload(ProfileColorFact fact) => fact.reload?.call();',
        imports: "import '../models/profile_colors.dart';",
      ),
    ),
    Case('unrelated ordinary error', page('String unrelated() => 3;')),
    Case(
      'candidate ordinary error',
      page(
        'String unrelated() => 3; Object? read() => AppPreferences();',
        imports: "import '../services/app_preferences.dart';",
      ),
      status: 2,
    ),
  ];
  final cliExits = <String, Set<int>>{
    'source': {},
    if (compiled != null) 'aot': {},
  };
  final workspace = Workspace();
  for (final fixture in cases) {
    workspace.load(fixture);
    try {
      List<Finding>? findings;
      var status = 0;
      try {
        findings = await rule.check(
          workspace.snapshot,
          workspace.root.path,
          sdkPath: sdk,
        );
        if (findings.isNotEmpty) status = 1;
      } on FormatException {
        status = 2;
      }
      require(
        status == fixture.status,
        '${fixture.name}: expected ${fixture.status}, got $status: $findings',
      );
      if (status == 1) {
        require(
          findings!.any(
            (f) =>
                f.id == rule.id &&
                f.file == fixture.file &&
                f.line == fixture.line,
          ),
          '${fixture.name}: missing canonical diagnostic/location: $findings',
        );
      }
      if (fixture.name == 'unrelated ordinary error') {
        final analysis = await runProofProcess(proofDartExecutable, [
          'analyze',
          '${workspace.root.path}/$view',
        ]);
        require(
          analysis.exitCode != 0 &&
              '${analysis.stdout}'.contains('return_of_invalid_type'),
          'SDK must reject ordinary noncandidate error',
        );
      }
      if (fixture.cli) {
        for (final (executable, prefix) in [
          (
            proofDartExecutable,
            ['run', 'tools/architecture/rules/profile_colours_view.dart'],
          ),
          if (compiled != null) (compiled, <String>[]),
        ]) {
          final result = await runProofProcess(executable, [
            ...prefix,
            '--root',
            workspace.root.path,
            '--roles',
            workspace.rolePath,
            '--sdk',
            sdk,
            '--json',
          ]);
          require(
            result.exitCode == fixture.status,
            '${fixture.name}: CLI ${result.exitCode} ${result.stdout}${result.stderr}',
          );
          cliExits[prefix.isEmpty ? 'aot' : 'source']!.add(result.exitCode);
          if (fixture.status == 1) {
            final output = jsonDecode(result.stdout as String) as Map;
            require(
              (output['findings'] as List).cast<Map>().any(
                (f) =>
                    f['id'] == rule.id &&
                    f['file'] == fixture.file &&
                    f['line'] == fixture.line,
              ),
              'actual CLI diagnostic provenance',
            );
          }
          if (fixture.status == 2) {
            require(
              '${result.stderr}'.contains('[${rule.id} INPUT]'),
              'actual CLI input diagnostic',
            );
          }
          if (fixture.status == 0) {
            final invalid = await runProofProcess(executable, [
              ...prefix,
              '--root',
              workspace.root.path,
              '--roles',
              workspace.rolePath,
              '--sdk',
              '${workspace.root.path}/missing-sdk',
            ]);
            require(
              invalid.exitCode == 2 &&
                  '${invalid.stderr}'.contains('[${rule.id} INPUT]'),
              'actual invalid SDK input',
            );
          }
        }
      }
      stdout.writeln('PASS ${fixture.name}');
    } finally {
      workspace.close();
    }
  }
  require(
    cliExits.values.every((exits) => exits.containsAll({0, 1, 2})),
    'Every enabled CLI mode must prove rejection, acceptance and input failure',
  );
  await _cacheTransitions(sdk, compiled);
  stdout.writeln(
    '${cases.length} colour view cases + 10 reused-cache transitions; actual source${compiled == null ? '' : '/fresh-AOT'} CLI1/0/2 and invalidSDK2; dual mandatory SDK proof',
  );
}

Future<void> _cacheTransitions(String sdk, String? compiled) async {
  final workspace = Workspace()
    ..load(
      Case(
        'cache base',
        page(
          'Object? read() => cached;',
          imports: "import '../../bridge.dart';",
        ),
        extra: {'lib/bridge.dart': "String get cached => 'safe';"},
      ),
    );
  final root = workspace.root.path;
  final originalView = File('$root/$view').readAsStringSync();
  final originalBridge = File('$root/lib/bridge.dart').readAsStringSync();
  void put(String path, String content) {
    final file = File('$root/$path');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  Future<void> status(int expected, String label) async {
    var actual = 0;
    List<Finding> findings = [];
    try {
      findings = await rule.check(workspace.snapshot, root, sdkPath: sdk);
      if (findings.isNotEmpty) actual = 1;
    } on FormatException {
      actual = 2;
    }
    require(actual == expected, '$label: expected $expected, actual $actual');
    if (actual == 1) {
      require(
        findings.any((f) => f.id == rule.id && f.file == view && f.line > 0),
        '$label: exact boundary diagnostic provenance',
      );
    }
  }

  try {
    await status(0, 'warm original observation');
    put(
      view,
      page(
        "Object? read(SharedPreferences p) => p.getInt('x');",
        imports: prefs,
      ),
    );
    await status(1, 'same-root source mutation');
    put(view, originalView);
    await status(0, 'restored source');
    stdout.writeln('PASS cache source transition');

    put(
      'lib/bridge.dart',
      "import 'core/services/app_preferences.dart'; AppPreferences get cached => AppPreferences();",
    );
    await status(1, 'same-path dependency type mutation');
    put('lib/bridge.dart', originalBridge);
    await status(0, 'restored dependency type');
    stdout.writeln('PASS cache dependency transition');

    File('$root/lib/bridge.dart').renameSync('$root/lib/bridge.dart.held');
    await status(2, 'removed dependency');
    File('$root/lib/bridge.dart.held').renameSync('$root/lib/bridge.dart');
    await status(0, 'restored removed dependency');
    stdout.writeln('PASS cache missing dependency transition');

    put(
      'lib/bridge.dart',
      "export 'core/services/app_preferences.dart'; $originalBridge",
    );
    await status(1, 'changed visible export namespace');
    put('lib/bridge.dart', originalBridge);
    await status(0, 'restored export namespace');
    stdout.writeln('PASS cache export transition');

    put(
      'lib/core/widgets/cached_colour_part.dart',
      "part of 'profile_selector.dart'; String key() => 'profile_color_v1_dummy';",
    );
    put(
      view,
      "import '../../bridge.dart'; part 'cached_colour_part.dart'; class ProfileSelector { Object? read() => cached; }",
    );
    // Part findings correctly belong to the actual part, not the primary file.
    final part = await rule.check(workspace.snapshot, root, sdkPath: sdk);
    require(
      part.any(
        (f) =>
            f.id == rule.id &&
            f.file == 'lib/core/widgets/cached_colour_part.dart' &&
            f.line == 1,
      ),
      'cached actual part insertion diagnostic',
    );
    put(view, originalView);
    File('$root/lib/core/widgets/cached_colour_part.dart').deleteSync();
    await status(0, 'restored part graph');
    stdout.writeln('PASS cache actual part transition');

    final config = File('$root/.dart_tool/package_config.json');
    final originalConfig = config.readAsStringSync();
    final data = jsonDecode(originalConfig) as Map;
    put('lib/package_safe/bridge.dart', originalBridge);
    put(
      'lib/package_changed/bridge.dart',
      "import '${File('$root/lib/core/services/app_preferences.dart').uri}'; AppPreferences get cached => AppPreferences();",
    );
    final mapping = {
      'name': 'colour_bridge',
      'rootUri': '../lib/package_safe/',
      'packageUri': '',
    };
    (data['packages'] as List).add(mapping);
    config.writeAsStringSync(jsonEncode(data));
    put(
      view,
      page(
        'Object? read() => cached;',
        imports: "import 'package:colour_bridge/bridge.dart';",
      ),
    );
    await status(0, 'original package origin');
    mapping['rootUri'] = '../lib/package_changed/';
    config.writeAsStringSync(jsonEncode(data));
    await status(1, 'changed same-name package origin');
    put(
      'lib/package_changed/bridge.dart',
      "import '${File('$root/lib/core/models/profile_colors.dart').uri}'; String get cached => ProfileColorChoice.automatic.name;",
    );
    await status(0, 'valid absolute package dependency namespace');
    put(
      'lib/package_changed/bridge.dart',
      "import '../core/models/profile_colors.dart'; String get cached => ProfileColorChoice.automatic.name;",
    );
    await status(2, 'malformed package-relative namespace despite disk file');
    put(
      'lib/package_changed/bridge.dart',
      "import '${File('$root/lib/core/models/profile_colors.dart').uri}'; String get cached => ProfileColorChoice.automatic.name;",
    );
    await status(0, 'restored actual package dependency namespace');
    Future<void> packagePartCli(int expected, String label) async {
      final arguments = [
        '--root',
        root,
        '--roles',
        workspace.rolePath,
        '--sdk',
        sdk,
        '--json',
      ];
      for (final command in [
        [
          '$sdk/bin/dart',
          'run',
          'tools/architecture/rules/profile_colours_view.dart',
        ],
        if (compiled != null) [compiled],
      ]) {
        final result = await runProofProcess(command.first, [
          ...command.skip(1),
          ...arguments,
        ]);
        require(
          result.exitCode == expected,
          '$label actual CLI expected $expected: ${result.stdout}${result.stderr}',
        );
        require(
          expected == 0
              ? ((jsonDecode(result.stdout as String) as Map)['findings']
                        as List)
                    .isEmpty
              : '${result.stderr}'.contains('[${rule.id} INPUT]'),
          '$label actual CLI diagnostic',
        );
      }
    }

    put(
      'lib/package_changed/bridge.dart',
      "library bridge; part '../piece.dart';",
    );
    put('lib/piece.dart', "part of bridge; String get cached => 'safe';");
    await status(2, 'package part escapes actual namespace despite disk file');
    await packagePartCli(2, 'missing actual package part');
    put(
      'lib/package_changed/bridge.dart',
      "library bridge; part 'piece.dart';",
    );
    put(
      'lib/package_changed/piece.dart',
      "part of bridge; String get cached => 'safe';",
    );
    await status(0, 'valid actual package part namespace');
    await packagePartCli(0, 'valid actual package part');
    config.writeAsStringSync(originalConfig);
    put(view, originalView);
    await status(0, 'restored package configuration');
    stdout.writeln('PASS cache package namespace transition');

    put(
      view,
      page('Object? render() => const Color(0);', imports: "import 'dart:ui';"),
    );
    await status(0, 'actual SDK embedder namespace');
    put(view, page('', imports: "import 'dart:wing_missing';"));
    await status(2, 'changed SDK namespace existence');
    put(view, originalView);
    await status(0, 'restored authored SDK namespace');
    stdout.writeln('PASS cache SDK namespace transition');

    put(
      'analysis_options.yaml',
      'analyzer:\n  strong-mode:\n    implicit-casts: false\n',
    );
    await status(0, 'changed root options');
    put(
      view,
      page(
        'String invalid() => 3; Object? read() => cached;',
        imports: "import '../../bridge.dart';",
      ),
    );
    await status(2, 'current candidate semantic error after options change');
    put(view, originalView);
    File('$root/analysis_options.yaml').deleteSync();
    await status(0, 'restored options');
    stdout.writeln('PASS cache options transition');

    final concurrent = await Future.wait([
      rule.check(workspace.snapshot, root, sdkPath: sdk),
      rule.check(workspace.snapshot, root, sdkPath: sdk),
    ]);
    require(
      concurrent.every((f) => f.isEmpty),
      'same-root concurrent cache stores',
    );
    stdout.writeln('PASS cache concurrent-store transition');

    final corrupt = Workspace()
      ..load(
        Case(
          'corrupt cache base',
          page(
            'Object? read() => cached;',
            imports: "import '../../bridge.dart';",
          ),
          extra: {'lib/bridge.dart': originalBridge},
        ),
      );
    Future<void> corruptCli() async {
      final result = await runProofProcess('$sdk/bin/dart', [
        'run',
        'tools/architecture/rules/profile_colours_view.dart',
        '--root',
        corrupt.root.path,
        '--roles',
        corrupt.rolePath,
        '--sdk',
        sdk,
        '--json',
      ]);
      require(
        result.exitCode == 0 &&
            ((jsonDecode(result.stdout as String) as Map)['findings'] as List)
                .isEmpty,
        'corrupt-summary actual CLI: ${result.stdout}${result.stderr}',
      );
    }

    try {
      // Process completion establishes quiescence of the producer's standard
      // async byte writer; no old writer can undo this deliberate corruption.
      await corruptCli();
      final cache = Directory(
        '${corrupt.root.path}/.dart_tool/architecture/profile-colours-view',
      );
      final records = cache
          .listSync(recursive: true)
          .whereType<File>()
          .toList();
      require(records.isNotEmpty, 'real standard summaries were populated');
      for (final record in records) {
        record.writeAsBytesSync([0]);
      }
      await corruptCli();
    } finally {
      corrupt.close();
    }
    stdout.writeln('PASS cache corrupt-summary transition');
  } finally {
    workspace.close();
  }
}
