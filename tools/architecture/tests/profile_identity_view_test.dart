import 'dart:convert';
import 'dart:io';

import '../dart_sdk.dart';
import '../proof_process.dart';
import '../model.dart';
import '../rules/profile_identity_view.dart' as rule;

const admin = 'lib/core/services/administration_repository.dart';
const gateway = 'lib/core/services/profile_gateway.dart';
const rawImport =
    "import 'package:wing/core/services/administration_repository.dart';";
const sessionImport =
    "import 'package:wing/core/services/profile_identity_edit_session.dart';";
const modelImport =
    "import 'package:wing/core/models/profile_identity_edit.dart';";
const raw =
    'class ProfileAdministration { void read() {} void write() {} }\nProfileAdministration get authority => ProfileAdministration();';
const owner =
    "$rawImport\nclass ProfileIdentityEditSession { ProfileIdentityEditSession(); void load() {} void save() {} void resolve() {} ProfileAdministration get profile => authority; }";
const domain =
    'enum ProfileIdentityField { description, soul }\nclass ProfileIdentityEditIntent { ProfileIdentityEditIntent(); void resolve() {} }\nString normalizeProfileIdentityText(Object field, String value) => value;';

const passiveOwner =
    'enum ProfileIdentitySaveOutcome { confirmed }\n'
    'class ProfileIdentityFieldState { const ProfileIdentityFieldState(this.text); final String text; }\n'
    'class ProfileIdentityEditState { const ProfileIdentityEditState(this.description); final ProfileIdentityFieldState description; }\n'
    'class ProfileIdentityEditSession { ProfileIdentityEditSession(); void load() {} void save() {} void resolve() {} ProfileIdentityEditState get state => const ProfileIdentityEditState(ProfileIdentityFieldState("")); }';

class Case {
  const Case(
    this.name,
    this.body, {
    this.extra = const {},
    this.bad = false,
    this.input = false,
    this.file = rule.view,
  });
  final String name, body, file;
  final Map<String, String> extra;
  final bool bad, input;
}

class Workspace {
  void load(Case fixture) {
    final sourcesRoot = Directory('${directory.path}/lib');
    if (sourcesRoot.existsSync()) sourcesRoot.deleteSync(recursive: true);
    final toolsRoot = Directory('${directory.path}/tools');
    if (toolsRoot.existsSync()) toolsRoot.deleteSync(recursive: true);
    final sources = {
      admin: raw,
      rule.session: owner,
      rule.model: domain,
      rule.view: fixture.body,
      ...fixture.extra,
    };
    final roles = <String, Object>{};
    for (final entry in sources.entries) {
      final file = File('${directory.path}/${entry.key}');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        entry.value.replaceAll('{{ROOT}}', directory.uri.toString()),
      );
      if (entry.key.startsWith('lib/')) {
        roles[entry.key] = {
          'role': 'application',
          'feature': 'identity',
          'library': entry.key,
        };
      }
    }
    File(
      rolesPath,
    ).writeAsStringSync(jsonEncode({'schema': 1, 'files': roles}));
    final original = File('.dart_tool/package_config.json');
    final configuration = jsonDecode(original.readAsStringSync()) as Map;
    final config = File('${directory.path}/.dart_tool/package_config.json');
    config.parent.createSync();
    config.writeAsStringSync(
      jsonEncode({
        ...configuration,
        'packages': [
          for (final package in (configuration['packages'] as List).cast<Map>())
            {
              ...package,
              'rootUri': package['name'] == 'wing'
                  ? directory.uri.toString()
                  : original.uri
                        .resolve(package['rootUri'] as String)
                        .toString(),
            },
        ],
      }),
    );
  }

  final directory = Directory.systemTemp.createTempSync('wing-identity-view-');
  String get rolesPath => '${directory.path}/roles.json';
  Snapshot get snapshot => Snapshot.load(directory.path, rolesPath);
  void dispose() => directory.deleteSync(recursive: true);
}

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main(List<String> args) =>
    withProofProcesses(() => _proofMain(args));

Future<void> _proofMain(List<String> args) async {
  String? compiled;
  if (args.isNotEmpty) {
    if (args.length != 2 ||
        args.first != '--compiled' ||
        !File(args.last).existsSync()) {
      throw const FormatException('Use [--compiled EXISTING_BINARY]');
    }
    compiled = File(args.last).absolute.path;
  }
  final sdk = dartSdkPath(Directory.current.path);
  final cases = [
    const Case(
      'direct raw constructor',
      '$rawImport\nclass AdminIdentityPage { final raw = ProfileAdministration(); }',
      bad: true,
    ),
    const Case(
      'prefixed constructor',
      "import 'package:wing/core/services/administration_repository.dart' as api;\nclass AdminIdentityPage { final raw = api.ProfileAdministration(); }",
      bad: true,
    ),
    const Case(
      'canonical type capture',
      '$rawImport\nclass AdminIdentityPage { void edit(ProfileAdministration raw) {} }',
      bad: true,
    ),
    const Case(
      'alias constructor',
      '$rawImport\ntypedef A = ProfileAdministration;\nclass AdminIdentityPage { final raw = A(); }',
      bad: true,
    ),
    const Case(
      'chained alias constructor',
      '$rawImport\ntypedef A = ProfileAdministration;\ntypedef B = A;\nclass AdminIdentityPage { final raw = B(); }',
      bad: true,
    ),
    const Case(
      'barrel alias',
      "import 'package:wing/bridge.dart';\nclass AdminIdentityPage { final raw = A(); }",
      bad: true,
      extra: {
        'lib/bridge.dart': '$rawImport\ntypedef A = ProfileAdministration;',
      },
    ),
    const Case(
      'canonical constructor capture',
      '$rawImport\nclass AdminIdentityPage { final create = ProfileAdministration.new; }',
      bad: true,
    ),
    const Case(
      'prefixed alias constructor capture',
      "import 'package:wing/bridge.dart' as b;\nclass AdminIdentityPage { final create = b.A.new; }",
      bad: true,
      extra: {
        'lib/bridge.dart': '$rawImport\ntypedef A = ProfileAdministration;',
      },
    ),
    const Case(
      'indirect raw getter call',
      '$rawImport\nclass AdminIdentityPage { void edit() { authority.read(); } }',
      bad: true,
    ),
    const Case(
      'indirect raw getter capture',
      '$rawImport\nclass AdminIdentityPage { final read = authority.read; }',
      bad: true,
    ),
    const Case(
      'canonical cascade',
      '$rawImport\nclass AdminIdentityPage { void edit() { authority..read(); } }',
      bad: true,
    ),
    const Case(
      'inherited raw operation',
      "import 'package:wing/bridge.dart';\nclass AdminIdentityPage extends Base { void edit() { read(); } }",
      bad: true,
      extra: {
        'lib/bridge.dart':
            '$rawImport\nclass Base extends ProfileAdministration {}',
      },
    ),
    const Case(
      'session authority escape',
      '$sessionImport\nclass AdminIdentityPage { final ProfileIdentityEditSession session; AdminIdentityPage(this.session); void edit() { session.profile.read(); } }',
      bad: true,
    ),
    const Case(
      'new duplicate session',
      '$sessionImport\nclass AdminIdentityPage { final session = ProfileIdentityEditSession(); }',
      bad: true,
    ),
    const Case(
      'captured session constructor',
      '$sessionImport\nclass AdminIdentityPage { final create = ProfileIdentityEditSession.new; }',
      bad: true,
    ),
    const Case(
      'intent construction',
      '$modelImport\nclass AdminIdentityPage { final intent = ProfileIdentityEditIntent(); }',
      bad: true,
    ),
    const Case(
      'indirect intent policy',
      "import 'package:wing/bridge.dart';\nclass AdminIdentityPage { void edit() { intent.resolve(); } }",
      bad: true,
      extra: {
        'lib/bridge.dart':
            '$modelImport\nProfileIdentityEditIntent get intent => ProfileIdentityEditIntent();',
      },
    ),
    const Case(
      'normalization function capture',
      '$modelImport\nclass AdminIdentityPage { final normalize = normalizeProfileIdentityText; }',
      bad: true,
    ),
    const Case(
      'json function capture',
      "import 'dart:convert';\nclass AdminIdentityPage { final decode = jsonDecode; }",
      bad: true,
    ),
    const Case(
      'json codec capture',
      "import 'dart:convert';\nclass AdminIdentityPage { final decode = utf8.decode; }",
      bad: true,
    ),
    const Case(
      'yaml function capture',
      "import 'package:yaml/yaml.dart' as y;\nclass AdminIdentityPage { final decode = y.loadYaml; }",
      bad: true,
    ),
    const Case(
      'metadata file IO',
      "import 'dart:io';\nclass AdminIdentityPage { final file = File('profile.yaml'); }",
      bad: true,
    ),
    const Case(
      'selected URI part',
      "$rawImport\npart 'identity_part.dart';\nclass AdminIdentityPage {}",
      bad: true,
      file: 'lib/core/screens/administration/identity_part.dart',
      extra: {
        'lib/core/screens/administration/identity_part.dart':
            "part of 'admin_identity_page.dart';\nfinal raw = authority.read;",
      },
    ),
    const Case(
      'selected named part',
      "library identity;\n$rawImport\npart 'identity_part.dart';\nclass AdminIdentityPage {}",
      bad: true,
      file: 'lib/core/screens/administration/identity_part.dart',
      extra: {
        'lib/core/screens/administration/identity_part.dart':
            'part of identity;\nfinal raw = authority.read;',
      },
    ),
    const Case(
      'definition part provenance',
      '$rawImport\nclass AdminIdentityPage { final raw = authority.read; }',
      bad: true,
      extra: {
        admin: "part 'administration_part.dart';",
        'lib/core/services/administration_part.dart':
            "part of 'administration_repository.dart';\n$raw",
      },
    ),
    const Case(
      'shown canonical constructor',
      "import 'package:wing/core/services/administration_repository.dart' show ProfileAdministration;\nclass AdminIdentityPage { final raw = ProfileAdministration(); }",
      bad: true,
    ),
    const Case(
      'unrelated shadow names',
      'class ProfileAdministration { void read() {} }\nclass AdminIdentityPage { final raw = ProfileAdministration(); void edit() { raw.read(); } }',
    ),
    const Case(
      'hidden canonical valid lookalike',
      "import 'package:wing/core/services/administration_repository.dart' hide ProfileAdministration;\nclass ProfileAdministration {}\nclass AdminIdentityPage { final raw = ProfileAdministration(); }",
    ),
    const Case(
      'unrelated json spelling',
      'String jsonDecode(String value) => value;\nclass AdminIdentityPage { final decode = jsonDecode; }',
    ),
    const Case(
      'session input commands and enum rendering',
      '$sessionImport\n$modelImport\nclass AdminIdentityPage { final ProfileIdentityEditSession session; AdminIdentityPage(this.session); void edit() { session.load(); session.save(); session.resolve(); final label = ProfileIdentityField.soul.name; } }',
    ),
    const Case(
      'aliased borrowed session commands',
      '$sessionImport\ntypedef Borrowed = ProfileIdentityEditSession;\nclass AdminIdentityPage { final Borrowed session; AdminIdentityPage(this.session); void edit() { session.load(); } }',
    ),
    const Case(
      'prefixed borrowed session commands',
      "import 'package:wing/core/services/profile_identity_edit_session.dart' as owner;\nclass AdminIdentityPage { final owner.ProfileIdentityEditSession session; AdminIdentityPage(this.session); void edit() { session.load(); } }",
    ),
    const Case(
      'local callbacks with raw operation spelling',
      'class AdminIdentityPage { void read() {} void edit() { read(); } }',
    ),
    const Case(
      'local callback does not hide qualified raw',
      '$rawImport\nclass AdminIdentityPage { void read() {} void edit() { authority.read(); } }',
      bad: true,
    ),
    const Case(
      'session receiver shadow is still resolved',
      "$sessionImport\nimport 'package:wing/bridge.dart' as b;\nclass AdminIdentityPage { final ProfileIdentityEditSession session; AdminIdentityPage(this.session); void edit(b.Raw session) { session.load(); } }",
      bad: true,
      extra: {
        'lib/bridge.dart':
            "import 'core/services/profile_identity_repository.dart';\ntypedef Raw = ProfileIdentityRepository;",
        'lib/core/services/profile_identity_repository.dart':
            'class ProfileIdentityRepository { void load() {} }',
      },
    ),
    const Case(
      'pattern receiver shadow still resolved',
      "$sessionImport\nimport 'package:wing/bridge.dart' as b;\nclass AdminIdentityPage { final ProfileIdentityEditSession session; AdminIdentityPage(this.session); void edit(b.Raw raw) { final (session,) = (raw,); session.load(); } }",
      bad: true,
      extra: {
        'lib/bridge.dart':
            "import 'core/services/profile_identity_repository.dart';\ntypedef Raw = ProfileIdentityRepository;",
        'lib/core/services/profile_identity_repository.dart':
            'class ProfileIdentityRepository { void load() {} }',
      },
    ),
    const Case(
      'loop receiver shadow still resolved',
      "$sessionImport\nimport 'package:wing/bridge.dart' as b;\nclass AdminIdentityPage { final ProfileIdentityEditSession session; AdminIdentityPage(this.session); void edit(List<b.Raw> rows) { for (final session in rows) { session.load(); } } }",
      bad: true,
      extra: {
        'lib/bridge.dart':
            "import 'core/services/profile_identity_repository.dart';\ntypedef Raw = ProfileIdentityRepository;",
        'lib/core/services/profile_identity_repository.dart':
            'class ProfileIdentityRepository { void load() {} }',
      },
    ),
    const Case(
      'capture indirect codec factory',
      "import 'dart:convert';\nimport 'package:wing/bridge.dart';\nclass AdminIdentityPage { final decode = createCodec().decode; }",
      bad: true,
      extra: {
        'lib/bridge.dart':
            "import 'dart:convert';\nJsonCodec createCodec() => const JsonCodec();",
      },
    ),
    const Case(
      'canonical module top-level capture',
      '$rawImport\nclass AdminIdentityPage { final reader = transport; }',
      bad: true,
      extra: {admin: '$raw\nfinal transport = authority.read;'},
    ),
    const Case(
      'canonical extension operation',
      '$rawImport\nclass AdminIdentityPage { void edit() { 1.wireRequest(); } }',
      bad: true,
      extra: {
        admin: '$raw\nextension Transport on int { void wireRequest() {} }',
      },
    ),
    const Case(
      'barrel shown canonical alias',
      "import 'package:wing/bridge.dart' show Borrowed;\nclass AdminIdentityPage { final raw = Borrowed(); }",
      bad: true,
      extra: {
        'lib/bridge.dart':
            "export 'core/services/administration_repository.dart' show ProfileAdministration;\nimport 'core/services/administration_repository.dart';\ntypedef Borrowed = ProfileAdministration;",
      },
    ),
    const Case(
      'outside-lib authored alias is not omitted',
      "import '{{ROOT}}tools/alias.dart';\nclass AdminIdentityPage { final raw = Borrowed(); }",
      input: true,
      extra: {
        'tools/alias.dart':
            '$rawImport\ntypedef Borrowed = ProfileAdministration;',
      },
    ),
    const Case(
      'unknown package clean input',
      "import 'package:missing/scope.dart';\nclass AdminIdentityPage {}",
      input: true,
    ),
    const Case(
      'missing raw namespace clean input',
      "import 'package:wing/missing.dart';\nclass AdminIdentityPage {}",
      input: true,
    ),
    const Case(
      'canonical enum capture',
      "import 'package:wing/core/services/profiles_repository.dart';\nclass AdminIdentityPage { final policy = ProfilesCapability.authenticationRequired; }",
      bad: true,
      extra: {
        'lib/core/services/profiles_repository.dart':
            'enum ProfilesCapability { authenticationRequired }',
      },
    ),
    const Case(
      'canonical enum type',
      "import 'package:wing/core/services/profiles_repository.dart';\nclass AdminIdentityPage { void render(ProfilesCapability policy) {} }",
      bad: true,
      extra: {
        'lib/core/services/profiles_repository.dart':
            'enum ProfilesCapability { authenticationRequired }',
      },
    ),
    const Case(
      'local enum same spelling',
      'enum ProfilesCapability { authenticationRequired }\nclass AdminIdentityPage { final policy = ProfilesCapability.authenticationRequired; }',
    ),
    const Case(
      'canonical mixin type',
      '$rawImport\nclass AdminIdentityPage with TransportMixin {}',
      bad: true,
      extra: {admin: '$raw\nmixin TransportMixin {}'},
    ),
    const Case(
      'canonical extension type constructor',
      '$rawImport\nclass AdminIdentityPage { final raw = TransportBox(1); }',
      bad: true,
      extra: {admin: '$raw\nextension type TransportBox(int value) {}'},
    ),
    const Case(
      'actual file URI part cannot disappear',
      "$rawImport\npart '{{ROOT}}tools/identity_piece.dart';\nclass AdminIdentityPage {}",
      input: true,
      extra: {
        'tools/identity_piece.dart':
            "part of '{{ROOT}}lib/core/screens/administration/admin_identity_page.dart';\nfinal saved = authority.read;",
      },
    ),
    const Case(
      'relative outside-lib actual part cannot disappear',
      "$rawImport\npart '../../../../tools/identity_piece.dart';\nclass AdminIdentityPage {}",
      input: true,
      extra: {
        'tools/identity_piece.dart':
            "part of '../lib/core/screens/administration/admin_identity_page.dart';\nfinal saved = authority.read;",
      },
    ),
    const Case(
      'canonical JsonUtf8Encoder constructor',
      "import 'dart:convert';\nclass AdminIdentityPage { final codec = JsonUtf8Encoder(); }",
      bad: true,
    ),
    const Case(
      'codec alias through barrel',
      "import 'package:wing/bridge.dart';\nclass AdminIdentityPage { final codec = UtfCodec(); }",
      bad: true,
      extra: {
        'lib/bridge.dart':
            "import 'dart:convert';\ntypedef UtfCodec = JsonUtf8Encoder;",
      },
    ),
    const Case(
      'codec same-spelling local valid',
      'class JsonUtf8Encoder {}\nclass AdminIdentityPage { final codec = JsonUtf8Encoder(); }',
    ),
    const Case(
      'unrelated semantic error belongs to standard SDK',
      "class AdminIdentityPage { int render() => 'wrong'; }",
    ),
    const Case(
      'canonical function typedef reference',
      '$rawImport\nclass AdminIdentityPage { void use(WireRead reader) {} }',
      bad: true,
      extra: {admin: '$raw\ntypedef WireRead = void Function();'},
    ),
    const Case(
      'implicit session construction cannot bypass factory',
      '$sessionImport\nclass AdminIdentityPage extends ProfileIdentityEditSession {}',
      bad: true,
    ),
    const Case(
      'explicit superclass session construction',
      '$sessionImport\nclass AdminIdentityPage extends ProfileIdentityEditSession { AdminIdentityPage() : super(); }',
      bad: true,
    ),
    const Case(
      'owner getter raw authority capture with novel name',
      '$sessionImport\nclass AdminIdentityPage { final ProfileIdentityEditSession owner; AdminIdentityPage(this.owner); Object capture() => owner.transport; }',
      bad: true,
      extra: {
        rule.session:
            '$owner\nextension OwnerTransport on ProfileIdentityEditSession { ProfileAdministration get transport => authority; }',
      },
    ),
    const Case(
      'owner method raw authority capture',
      '$sessionImport\nclass AdminIdentityPage { final ProfileIdentityEditSession owner; AdminIdentityPage(this.owner); Object capture() => owner.borrowTransport(); }',
      bad: true,
      extra: {
        rule.session:
            '$owner\nextension OwnerTransport on ProfileIdentityEditSession { ProfileAdministration borrowTransport() => authority; }',
      },
    ),
    const Case(
      'internal YAML canonical type',
      "import 'package:yaml/src/error_listener.dart';\nclass AdminIdentityPage { void render(ErrorListener listener) {} }",
      bad: true,
    ),
    const Case(
      'file URI bridge cannot hide an outside-lib actual part',
      "import '{{ROOT}}lib/bridge.dart';\nclass AdminIdentityPage { final raw = Secret(); }",
      input: true,
      extra: {
        'lib/bridge.dart': "$rawImport\npart '../tools/bridge_piece.dart';",
        'tools/bridge_piece.dart':
            "part of '../lib/bridge.dart';\ntypedef Secret = ProfileAdministration;",
      },
    ),
    const Case(
      'supported file URI alias import retains provenance',
      "import '{{ROOT}}lib/bridge.dart';\nclass AdminIdentityPage { final raw = Alias(); }",
      bad: true,
      extra: {
        'lib/bridge.dart': '$rawImport\ntypedef Alias = ProfileAdministration;',
      },
    ),
    const Case(
      'imported forbidden String annotation cannot become passive',
      '$sessionImport\nclass AdminIdentityPage { final ProfileIdentityEditSession owner; AdminIdentityPage(this.owner); Object capture() => owner.raw; }',
      bad: true,
      extra: {
        admin: '$raw\nclass String {}',
        rule.session:
            '$rawImport\nclass ProfileIdentityEditSession { ProfileIdentityEditSession(); String get raw => String(); }',
      },
    ),
    const Case(
      'imported forbidden Future annotation cannot become passive',
      '$sessionImport\nclass AdminIdentityPage { final ProfileIdentityEditSession owner; AdminIdentityPage(this.owner); Object capture() => owner.raw; }',
      bad: true,
      extra: {
        admin: '$raw\nclass Future<T> {}',
        rule.session:
            '$rawImport\nclass ProfileIdentityEditSession { ProfileIdentityEditSession(); Future<int> get raw => Future<int>(); }',
      },
    ),
    const Case(
      'passive class spelling cannot certify an authority alias',
      '$sessionImport\nclass AdminIdentityPage { void render(ProfileIdentityFieldState state) {} }',
      bad: true,
      extra: {
        rule.session:
            '$owner\ntypedef ProfileIdentityFieldState = ProfileAdministration;',
      },
    ),
    const Case(
      'generic passive class authority substitution remains semantic',
      '$rawImport\n$sessionImport\nclass AdminIdentityPage { void render(ProfileIdentityFieldState<ProfileAdministration> state) {} }',
      bad: true,
      extra: {
        rule.session:
            '$owner\nclass ProfileIdentityFieldState<T> { final T text; ProfileIdentityFieldState(this.text); }',
      },
    ),
    const Case(
      'nullable novel owner authority capture remains semantic',
      '$sessionImport\nclass AdminIdentityPage { final ProfileIdentityEditSession owner; AdminIdentityPage(this.owner); Object? capture() => owner.transport; }',
      bad: true,
      extra: {
        rule.session:
            '$owner\nextension OwnerTransport on ProfileIdentityEditSession { ProfileAdministration? get transport => authority; }',
      },
    ),
    const Case(
      'function typed formal cannot borrow a same named session field',
      '$sessionImport\n$rawImport\nclass AdminIdentityPage { final ProfileIdentityEditSession owner; AdminIdentityPage(this.owner); Object capture(void owner()) => owner.read; }',
      bad: true,
      extra: {
        admin:
            '$raw\nextension FunctionTransport on void Function() { ProfileAdministration get read => authority; }',
      },
    ),
    const Case(
      'super formal receiver uncertainty remains a semantic input error',
      "$sessionImport\nimport 'package:wing/bridge.dart';\nlate ProfileIdentityEditSession borrowed;\nclass AdminIdentityPage extends Base { final ProfileIdentityEditSession owner; AdminIdentityPage({required super.owner}) : owner = borrowed { owner.read(); } }",
      input: true,
      extra: {
        'lib/bridge.dart':
            '$rawImport\nclass Base { Base({required ProfileAdministration owner}); }',
      },
    ),
    const Case(
      'cascade cannot borrow a local callback with the same name',
      '$rawImport\nclass AdminIdentityPage { void read() {} void render() { authority..read(); } }',
      bad: true,
    ),
    const Case(
      'Flutter controller spelling cannot certify a raw authority',
      "import 'package:flutter/material.dart' hide TextEditingController;\n$rawImport\nclass AdminIdentityPage { final editor = TextEditingController(); Object capture() => editor.text; }",
      bad: true,
      extra: {
        admin:
            '$raw\nclass TextEditingController { ProfileAdministration get text => authority; void dispose() {} }',
      },
    ),
    const Case(
      'passive DTO novel raw getter remains semantic',
      '$sessionImport\nclass AdminIdentityPage { final ProfileIdentityFieldState state; AdminIdentityPage(this.state); Object capture() => state.transport; }',
      bad: true,
      extra: {
        rule.session:
            '$owner\nclass ProfileIdentityFieldState { ProfileAdministration get transport => authority; }',
      },
    ),
    const Case(
      'same named passive enum cannot certify canonical raw static access',
      "$rawImport\nimport 'package:wing/core/models/profile_identity_edit.dart' hide ProfileIdentityField;\nclass AdminIdentityPage { final value = ProfileIdentityField.description; }",
      bad: true,
      extra: {
        admin:
            '$raw\nclass ProfileIdentityField { static ProfileAdministration get description => authority; }',
      },
    ),
    const Case(
      'canonical passive facts through explicit getter',
      '$sessionImport\nclass AdminIdentityPage { final ProfileIdentityEditSession owner; AdminIdentityPage(this.owner); ProfileIdentityEditState get state => owner.state; String render() => state.description.text; void retry() => owner.load(); }',
      extra: {rule.session: passiveOwner},
    ),
    const Case(
      'canonical passive facts via prefixed barrel',
      "import 'package:wing/bridge.dart' as facts;\nclass AdminIdentityPage { final facts.ProfileIdentityEditSession owner; AdminIdentityPage(this.owner); facts.ProfileIdentityEditState get state => owner.state; String render() => state.description.text; }",
      extra: {
        rule.session: passiveOwner,
        'lib/bridge.dart':
            "export 'core/services/profile_identity_edit_session.dart' show ProfileIdentityEditSession, ProfileIdentityEditState;",
      },
    ),
    const Case(
      'canonical passive declaration part retains provenance',
      '$sessionImport\nclass AdminIdentityPage { final ProfileIdentityFieldState state; AdminIdentityPage(this.state); String render() => state.text; }',
      extra: {
        rule.session:
            "part 'identity_state.dart';\nclass ProfileIdentityEditSession {}",
        'lib/core/services/identity_state.dart':
            "part of 'profile_identity_edit_session.dart';\nclass ProfileIdentityFieldState { final String text; ProfileIdentityFieldState(this.text); }",
      },
    ),
    const Case(
      'unrelated local String annotation remains legitimate',
      '$sessionImport\nclass AdminIdentityPage { final ProfileIdentityEditSession owner; AdminIdentityPage(this.owner); Object capture() => owner.raw; }',
      extra: {
        rule.session:
            'class String {}\nclass ProfileIdentityEditSession { ProfileIdentityEditSession(); String get raw => String(); }',
      },
    ),
    const Case(
      'unrelated local passive enum spelling remains legitimate',
      '$sessionImport\nenum ProfileIdentitySaveOutcome { confirmed }\nclass AdminIdentityPage { final value = ProfileIdentitySaveOutcome.confirmed; }',
      extra: {rule.session: passiveOwner},
    ),
    const Case(
      'passive only semantic error belongs to standard SDK',
      '$sessionImport\nclass AdminIdentityPage { final ProfileIdentityEditSession owner; AdminIdentityPage(ProfileIdentityEditSession borrowed) : owner = borrowed; ProfileIdentityEditState get state => owner.state; String render() => state.description.text; int unrelated() => "wrong"; }',
      extra: {rule.session: passiveOwner},
    ),
    const Case(
      'named extension homonym prevents passive namespace proof',
      "$modelImport\n$sessionImport\nimport 'package:wing/bridge.dart';\nclass AdminIdentityPage { final value = ProfileIdentityField.description; }",
      input: true,
      extra: {
        rule.session: passiveOwner,
        'lib/bridge.dart':
            '$rawImport\nextension ProfileIdentityField on ProfileAdministration {}',
      },
    ),
    const Case(
      'session spelling authority alias cannot bypass canonical type capture',
      "import 'package:wing/bridge.dart';\nclass AdminIdentityPage { void capture(ProfileIdentityEditSession value) {} }",
      bad: true,
      extra: {
        'lib/bridge.dart':
            '$rawImport\ntypedef ProfileIdentityEditSession = ProfileAdministration;',
      },
    ),
    const Case(
      'unrelated local session spelling remains legitimate',
      'class ProfileIdentityEditSession {}\nclass AdminIdentityPage { void render(ProfileIdentityEditSession value) {} }',
    ),
    const Case(
      'malformed selected input',
      'class AdminIdentityPage {',
      input: true,
    ),
    const Case('missing selected class', 'class Other {}', input: true),
    const Case(
      'missing selected part',
      "part 'missing.dart';\nclass AdminIdentityPage {}",
      input: true,
    ),
    const Case(
      'mismatched selected named part',
      "library identity;\npart 'identity_part.dart';\nclass AdminIdentityPage {}",
      input: true,
      extra: {
        'lib/core/screens/administration/identity_part.dart': 'part of wrong;',
      },
    ),
    const Case(
      'orphan selected library',
      "part of 'owner.dart';\nclass AdminIdentityPage {}",
      input: true,
    ),
    const Case(
      'conditional imports need proof',
      "import 'package:wing/core/services/administration_repository.dart' if (dart.library.io) 'package:wing/other.dart';\nclass AdminIdentityPage {}",
      input: true,
      extra: {'lib/other.dart': raw},
    ),
    const Case(
      'unresolved canonical candidate',
      '$rawImport\nclass AdminIdentityPage { void edit() { authority.read(unknown); } }',
      input: true,
    ),
  ];
  final workspace = Workspace();
  try {
    await verifyCases(cases, workspace, sdk, compiled);
  } finally {
    workspace.dispose();
  }
}

Future<void> verifyCases(
  List<Case> cases,
  Workspace workspace,
  String sdk,
  String? compiled,
) async {
  var passed = 0;
  for (final fixture in cases) {
    workspace.load(fixture);
    try {
      final findings = await rule.check(
        workspace.snapshot,
        workspace.directory.path,
        sdkPath: sdk,
      );
      require(!fixture.input, '${fixture.name}: expected input rejection');
      require(
        fixture.bad ? findings.isNotEmpty : findings.isEmpty,
        '${fixture.name}: findings=$findings',
      );
      require(
        findings.every(
          (f) => f.id == rule.id && f.file == fixture.file && f.line >= 2,
        ),
        '${fixture.name}: diagnostic provenance',
      );
    } on FormatException {
      require(fixture.input, '${fixture.name}: unexpected input rejection');
    }
    final expected = fixture.input
        ? 2
        : fixture.bad
        ? 1
        : 0;
    // Representative ordinary CLI proofs; every fixture uses freshly compiled
    // CLI when requested, including SDK/provenance branches.
    if (compiled != null ||
        passed == 0 ||
        fixture.name == 'local callbacks with raw operation spelling' ||
        fixture.name == 'malformed selected input' ||
        fixture.name == 'canonical enum capture' ||
        fixture.name == 'actual file URI part cannot disappear' ||
        fixture.name == 'canonical JsonUtf8Encoder constructor' ||
        fixture.name ==
            'session spelling authority alias cannot bypass canonical type capture' ||
        fixture.name == 'passive only semantic error belongs to standard SDK') {
      final arguments = [
        '--root',
        workspace.directory.path,
        '--roles',
        workspace.rolesPath,
        '--sdk',
        sdk,
        '--json',
      ];
      final process = await runProofProcess(
        compiled ?? proofDartExecutable,
        compiled == null
            ? [
                'run',
                'tools/architecture/rules/profile_identity_view.dart',
                ...arguments,
              ]
            : arguments,
      );
      require(
        process.exitCode == expected,
        '${fixture.name}: CLI ${process.exitCode} expected$expected ${process.stderr}',
      );
      if (expected != 2) {
        final output = jsonDecode(process.stdout as String) as Map;
        require(
          output['id'] == rule.id &&
              ((output['findings'] as List).isNotEmpty == fixture.bad),
          '${fixture.name}: CLI findings',
        );
      }
    }
    if (fixture.name == 'unrelated semantic error belongs to standard SDK' ||
        fixture.name == 'passive only semantic error belongs to standard SDK') {
      final standard = await runProofProcess(proofDartExecutable, [
        'analyze',
        '${workspace.directory.path}/${rule.view}',
      ]);
      require(
        standard.exitCode != 0 &&
            '${standard.stdout}${standard.stderr}'.contains(
              'return_of_invalid_type',
            ),
        'Noncandidate semantic error must fail standard SDK analysis',
      );
    }
    passed++;
  }
  workspace.load(
    const Case('SDK validation clean path', 'class AdminIdentityPage {}'),
  );
  var rejected = false;
  try {
    await rule.check(
      workspace.snapshot,
      workspace.directory.path,
      sdkPath: '/missing/identity-sdk',
    );
  } on FormatException {
    rejected = true;
  }
  require(rejected, 'SDK validation cannot be skipped on clean path');
  final arguments = [
    '--root',
    workspace.directory.path,
    '--roles',
    workspace.rolesPath,
    '--sdk',
    '/missing/identity-sdk',
    '--json',
  ];
  final process = await runProofProcess(
    compiled ?? proofDartExecutable,
    compiled == null
        ? [
            'run',
            'tools/architecture/rules/profile_identity_view.dart',
            ...arguments,
          ]
        : arguments,
  );
  require(process.exitCode == 2, 'Invalid SDK CLI expected2');
  stdout.writeln(
    '$passed identity-view fixtures + invalid SDK proof passed${compiled == null ? " (source)" : " (fresh compiled)"}',
  );
}
