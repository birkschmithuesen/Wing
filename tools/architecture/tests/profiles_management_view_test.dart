import 'dart:convert';
import 'dart:io';

import '../rules/profiles_management_view.dart' as rule;
import '../proof_process.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main(List<String> args) =>
    withProofProcesses(() => _proofMain(args));

Future<void> _proofMain(List<String> args) async {
  if (args.isNotEmpty && (args.length != 2 || args.first != '--compiled')) {
    throw const FormatException('Use [--compiled PATH]');
  }
  final root = await Directory.systemTemp.createTemp('wing-profiles-view-');
  Future<void> put(String path, String value) async {
    final file = File('${root.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsString(value);
  }

  try {
    await put(
      '.dart_tool/package_config.json',
      File('.dart_tool/package_config.json').readAsStringSync(),
    );
    await put('lib/core/services/profiles_management_session.dart', '''
class ProfilesManagementSession {
  void beginCreate() {} void reload() {} void dispose() {}
  String get title => 'Profiles';
}
class ProfilesManagementIntent {}
''');
    await put('lib/core/screens/administration/admin_widgets.dart', '''
class AdminGroup { const AdminGroup(); }
''');
    await put('lib/core/widgets/studio_loading.dart', '''
class StudioLoadingRegion { const StudioLoadingRegion(); }
''');
    await put('lib/core/widgets/selection_viewport.dart', '''
Object viewportSelection(Object child) => child;
void internalSelectionProtocol() {}
''');
    await put('lib/core/widgets/fake_selection.dart', '''
Object viewportSelection(Object child) => child;
''');
    await put('lib/core/widgets/studio_form_actions.dart', '''
class StudioFormActions { const StudioFormActions(); }
''');
    await put('lib/core/widgets/studio_error.dart', '''
class StudioError { const StudioError(this.message); final String message; }
''');
    await put('lib/core/widgets/form_presentation.dart', '''
export 'studio_form_actions.dart';
export 'studio_error.dart';
''');
    await put('lib/core/widgets/leaky_forms.dart', '''
export 'form_presentation.dart';
export '../services/administration_repository.dart';
''');
    await put('lib/core/theme/wing_theme.dart', '''
class StudioButtonPress { const StudioButtonPress({required this.child}); final Object child; }
class StudioPopupMenuItem { const StudioPopupMenuItem(); }
''');
    await put('lib/core/services/administration_repository.dart', '''
part 'repository_part.dart';
class AdministrationRepository { AdministrationRepository(); void request() {} }
''');
    await put('lib/core/services/repository_part.dart', '''
part of 'administration_repository.dart';
class ProfileAdministration { void write() {} }
''');
    await put('lib/core/services/profile_gateway.dart', '''
class ProfileGateway { ProfileGateway(); void post() {} }
''');
    await put('lib/core/services/connection_manager.dart', '''
class DashboardClient { void apiWriteOwned() {} }
''');
    await put('lib/core/services/profiles_repository.dart', '''
class ProfilesRepository { static void discover() {} }
''');
    await put('lib/core/models/hermes_profile.dart', '''
class HermesProfile { String get name => 'default'; }
''');
    await put('lib/core/services/profiles_view_barrel.dart', '''
export 'profiles_management_session.dart';
export 'administration_repository.dart';
''');
    await put('lib/core/services/profiles_view_alias.dart', '''
import 'administration_repository.dart';
typedef Selected = AdministrationRepository;
''');
    await put('lib/core/services/conditional_view.dart', '''
export 'profiles_management_session.dart'
    if (dart.library.io) 'administration_repository.dart';
''');
    const sessionImport =
        "import '../../services/profiles_management_session.dart';\n";
    const factory = '''
class AdminProfilesPage {
  final ProfilesManagementSession Function() createSession;
  AdminProfilesPage({required this.createSession});
}
''';
    String view(
      String source, {
      String imports = sessionImport,
      String declaration = factory,
    }) => '$imports$declaration$source';
    final invalid = <String>[
      view(
        'void f() { internalSelectionProtocol(); }',
        imports:
            '${sessionImport}import "../../widgets/selection_viewport.dart" show internalSelectionProtocol;\n',
      ),
      view(
        'Object f() => viewportSelection(1);',
        imports:
            '${sessionImport}import "../../widgets/selection_viewport.dart";\n',
      ),
      view(
        'Object f() => viewportSelection(1);',
        imports:
            '${sessionImport}import "../../widgets/fake_selection.dart";\n',
      ),
      view(
        'void f() { const StudioFormActions(); }',
        imports: '${sessionImport}import "../../widgets/leaky_forms.dart";\n',
      ),
      view(
        'void f(AdministrationRepository value) { value.request(); }',
        imports:
            '${sessionImport}import "../../services/administration_repository.dart";\n',
      ),
      view(
        'void f(api.AdministrationRepository value) { final read = value.request; read(); }',
        imports:
            '${sessionImport}import "../../services/administration_repository.dart" as api;\n',
      ),
      view(
        'typedef Store = api.AdministrationRepository; void f(Store value) { value..request(); }',
        imports:
            '${sessionImport}import "../../services/profiles_view_barrel.dart" as api show AdministrationRepository;\n',
      ),
      view(
        'class Local extends ProfileAdministration { void f() { final writeAgain = write; writeAgain(); } }',
        imports:
            '${sessionImport}import "../../services/administration_repository.dart";\n',
      ),
      view(
        'void f() { final make = Selected.new; make(); }',
        imports:
            '${sessionImport}import "../../services/profiles_view_alias.dart";\n',
      ),
      view(
        'void f(ProfileGateway value) { value.post(); }',
        imports:
            '${sessionImport}import "../../services/profile_gateway.dart";\n',
      ),
      view(
        'void f(DashboardClient value) { value.apiWriteOwned(); }',
        imports:
            '${sessionImport}import "../../services/connection_manager.dart";\n',
      ),
      view(
        'void f() { ProfilesRepository.discover(); }',
        imports:
            '${sessionImport}import "../../services/profiles_repository.dart";\n',
      ),
      view(
        "bool f(HermesProfile profile) => profile.name == 'default';",
        imports: '${sessionImport}import "../../models/hermes_profile.dart";\n',
      ),
      view('void f() {}', imports: '${sessionImport}import "dart:convert";\n'),
      view('void f() {}', imports: '${sessionImport}import "dart:io";\n'),
      view("Map<String, dynamic> f() => {'ok': true, 'name': 'x'};"),
      view(
        "typedef Wire = Map<String,Object?>; bool f(Wire value) => value['ok'] == true;",
      ),
      view(
        "dynamic f(Map<String,dynamic> value) { final alias = value; return alias['path']; }",
      ),
      view(
        "void f() { final value = <String,Object>{'title': 'x'}; value['title']; }",
      ),
      view(
        'void f() {}',
        declaration: '''
class AdminProfilesPage {
  final ProfilesManagementSession Function()? createSession;
  AdminProfilesPage({this.createSession});
}
''',
      ),
      view(
        'void f() {}',
        declaration: '''
class AdminProfilesPage {
  final ProfilesManagementSession Function() createSession;
  AdminProfilesPage({required this.createSession});
  AdminProfilesPage.optional(this.createSession);
}
''',
      ),
      view(
        'void f() {}',
        declaration: '''
class AdminProfilesPage {
  ProfilesManagementSession Function() createSession;
  AdminProfilesPage({required this.createSession});
}
''',
      ),
      view(
        'void f() {}',
        declaration: '''
class AdminProfilesPage {
  final String Function() createSession;
  AdminProfilesPage({required this.createSession});
}
''',
      ),
      view(
        'void f() {}',
        imports:
            '${sessionImport}export "../../services/profile_gateway.dart";\n',
      ),
    ];
    invalid.add(view('void f() { ProfilesManagementSession(); }'));
    invalid.add(
      view(
        'typedef Reader = Map<String,dynamic> Function(); void f(Reader read) { read(); }',
      ),
    );
    invalid.add(
      view('void f() { final make = ProfilesManagementSession.new; make(); }'),
    );
    final valid = <String>[
      view(
        'Object f() => viewportSelection(1);',
        imports:
            '${sessionImport}import "../../widgets/selection_viewport.dart" show viewportSelection;\n',
      ),
      view(
        'Object f() => selection.viewportSelection(1);',
        imports:
            '${sessionImport}import "../../widgets/selection_viewport.dart" as selection show viewportSelection;\n',
      ),
      view(
        'void f() { const StudioButtonPress(child: StudioPopupMenuItem()); }',
        imports: '${sessionImport}import "../../theme/wing_theme.dart";\n',
      ),
      view(
        'void f() { const StudioLoadingRegion(); }',
        imports:
            '${sessionImport}import "../../widgets/studio_loading.dart";\n',
      ),
      view(
        'void f(ProfilesManagementSession owner) { owner.beginCreate(); owner.reload(); }',
      ),
      view(
        'void f(ProfilesManagementSession owner) { final request = owner.reload; request(); }',
      ),
      view(
        'class ProfileGateway { void post() {} } void f(ProfileGateway value) { value..post(); }',
      ),
      view(
        'class Ui { void request() {} } void f(Ui value) { value.request(); }',
      ),
      view("Map<String,String> f() => {'default': 'Default profile'};"),
      view('class Ui {} Map<String,Ui> f() => {"label": Ui()};'),
      view('class Map<K,V> { Map(); } Map<String,dynamic> f() => Map();'),
      view(
        'typedef Create = ProfilesManagementSession Function(); void f() {}',
        declaration: '''
typedef Factory = ProfilesManagementSession Function();
class AdminProfilesPage {
  final Factory createSession;
  AdminProfilesPage({required this.createSession});
}
''',
      ),
      view(
        'void f() {}',
        imports:
            "import '../../services/profiles_view_barrel.dart' show ProfilesManagementSession;\n",
      ),
      view(
        'void f(ProfilesManagementSession session) { session.dispose(); }',
        imports:
            "import '../../services/profiles_view_barrel.dart' hide AdministrationRepository, ProfileAdministration;\n",
      ),
      view(
        'void f() { const AdminGroup(); }',
        imports: '${sessionImport}import "admin_widgets.dart";\n',
      ),
      view(
        "Object f() => [const ui.StudioFormActions(), const ui.StudioError('Failed')];",
        imports:
            '${sessionImport}import "../../widgets/form_presentation.dart" as ui;\n',
      ),
      view(
        "// profile.name == 'default'; repository.request();\nString f() => 'ProfileGateway.post';",
      ),
      view('void f(void Function() request) { request(); request.call(); }'),
    ];
    valid.add(
      view(
        'void f(api.ProfilesManagementSession owner) { owner.reload(); }',
        imports:
            "import '../../services/profiles_view_barrel.dart' as api show ProfilesManagementSession;\n",
        declaration:
            "class AdminProfilesPage { final api.ProfilesManagementSession Function() createSession; AdminProfilesPage({required this.createSession}); }",
      ),
    );
    valid.add(
      view(
        'class ProfilesManagementSession { void request() {} } void f(ProfilesManagementSession owner) { owner.request(); }',
        imports:
            "import '../../services/profiles_management_session.dart' as api;\n",
        declaration:
            "class AdminProfilesPage { final api.ProfilesManagementSession Function() createSession; AdminProfilesPage({required this.createSession}); }",
      ),
    );
    final input = <String>[
      view('void f() {'),
      view('void f() { MissingType(); }'),
      view('void f() {}', imports: '${sessionImport}import "absent.dart";\n'),
      view(
        'void f() {}',
        imports:
            '${sessionImport}import "../../services/profiles_management_session.dart" if (dart.library.io) "../../services/administration_repository.dart";\n',
      ),
      view(
        'void f() {}',
        imports:
            '${sessionImport}import "../../services/conditional_view.dart";\n',
      ),
      'void f() {}',
    ];
    // Genuine containing-library parts are inspected wherever physically placed.
    await put('tools/view_piece.dart', '''
part of '../lib/core/screens/administration/admin_profiles_page.dart';
Map<String,dynamic> protocol() => {'ok': true};
''');
    invalid.add(
      view(
        'void f() {}',
        imports:
            '${sessionImport}part "${File('${root.path}/tools/view_piece.dart').uri}";\n',
      ),
    );
    // Additive successor cases: all first 45 payloads remain unchanged above.
    final previousInvalid = invalid.length;
    invalid.addAll([
      view(
        'void f() {}',
        declaration:
            'class AdminProfilesPage { final ProfilesManagementSession Function()? createSession; AdminProfilesPage({required this.createSession}); }',
      ),
      view(
        'void f() {}',
        declaration:
            'class AdminProfilesPage { final ProfilesManagementSession? Function() createSession; AdminProfilesPage({required this.createSession}); }',
      ),
      view(
        'class Extra extends ProfilesManagementSession { Extra() : super(); } void f() { Extra(); }',
      ),
      view(
        'class Extra extends ProfilesManagementSession {} void f() { Extra(); }',
      ),
      view(
        'class Intermediate extends ProfilesManagementSession {} class Extra extends Intermediate {} void f() { Extra(); }',
      ),
      view(
        "void f() { const MethodChannel('profiles.review').invokeMethod<void>('mutate'); }",
        imports:
            "${sessionImport}import 'package:flutter/services.dart' show MethodChannel;\n",
      ),
      view(
        "void f() { final create = MethodChannel.new; create('profiles.review'); }",
        imports:
            "${sessionImport}import 'package:flutter/services.dart' show MethodChannel;\n",
      ),
      view(
        "typedef Native = api.MethodChannel; void f() { const Native('profiles.review').invokeMethod<void>('mutate'); }",
        imports:
            "${sessionImport}import 'package:flutter/services.dart' as api show MethodChannel;\n",
      ),
      view(
        "void f() { const BasicMessageChannel<String>('profiles.review', StringCodec()).send('mutate'); }",
        imports:
            "${sessionImport}import 'package:flutter/services.dart' show BasicMessageChannel, StringCodec;\n",
      ),
      view(
        "void f() { const EventChannel('profiles.review').receiveBroadcastStream(); }",
        imports:
            "${sessionImport}import 'package:flutter/services.dart' show EventChannel;\n",
      ),
    ]);
    valid.addAll([
      view(
        'class Local { Local(); } class Extra extends Local { Extra() : super(); } void f() { Extra(); }',
      ),
      view(
        'class Local { Local(); } class Extra extends Local {} void f() { Extra(); }',
      ),
      view(
        "void f() { Clipboard.setData(const ClipboardData(text: 'profile')); SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]); }",
        imports:
            "${sessionImport}import 'package:flutter/services.dart' show Clipboard, ClipboardData, SystemChrome, DeviceOrientation;\n",
      ),
      view(
        "class MethodChannel { MethodChannel(String name); void invokeMethod() {} } void f() { MethodChannel('profiles.review').invokeMethod(); }",
      ),
    ]);
    // The complete predecessor's 59 payloads/support remain above unchanged.
    // Ordinary semantics remain INPUT2 even with a populated summary cache.
    input.addAll([
      view('String unrelated() => 3;'),
      view('void f(ProfilesManagementSession owner) { owner.absentMember(); }'),
    ]);
    final viewFile = File('${root.path}/${rule.completedView}');
    await viewFile.parent.create(recursive: true);
    for (var index = 0; index < invalid.length; index++) {
      await viewFile.writeAsString(invalid[index]);
      final List findings;
      try {
        findings = await rule.check(root);
      } catch (error) {
        throw StateError('invalid $index: $error');
      }
      require(findings.isNotEmpty, 'invalid $index must fail');
      require(
        findings.every((finding) => finding.id == rule.id && finding.line > 0),
        'invalid $index diagnostic identity/location',
      );
    }
    for (var index = 0; index < valid.length; index++) {
      await viewFile.writeAsString(valid[index]);
      require((await rule.check(root)).isEmpty, 'valid $index');
    }
    for (var index = 0; index < input.length; index++) {
      await viewFile.writeAsString(input[index]);
      var refused = false;
      try {
        await rule.check(root);
      } on FormatException {
        refused = true;
      }
      require(refused, 'input $index');
    }
    // Reuse the SAME cache after changing real input bytes, not just a fixture
    // root. Analyzer must rederive current types/diagnostics/namespaces.
    final sessionFile = File(
      '${root.path}/lib/core/services/profiles_management_session.dart',
    );
    final originalSession = await sessionFile.readAsString();
    final observation = view(
      'void f(ProfilesManagementSession owner) { final value = owner.title; value.toString(); }',
    );
    await viewFile.writeAsString(observation);
    require((await rule.check(root)).isEmpty, 'cached original API clean');
    await sessionFile.writeAsString(
      originalSession.replaceFirst(
        "String get title => 'Profiles';",
        "Map<String,dynamic> get title => {'profile': 'x'};",
      ),
    );
    require(
      (await rule.check(root)).any((finding) => finding.id == rule.id),
      'cached dependency API mutation fails',
    );
    await sessionFile.writeAsString(originalSession);
    require((await rule.check(root)).isEmpty, 'restored dependency API clean');
    await viewFile.writeAsString(view('String unrelated() => 3;'));
    var semanticFailure = false;
    try {
      await rule.check(root);
    } on FormatException {
      semanticFailure = true;
    }
    require(semanticFailure, 'cached unrelated semantic error is INPUT');
    await viewFile.writeAsString(valid.first);
    await sessionFile.rename('${sessionFile.path}.held');
    var missingDependency = false;
    try {
      await rule.check(root);
    } on FormatException {
      missingDependency = true;
    }
    await File('${sessionFile.path}.held').rename(sessionFile.path);
    require(missingDependency, 'cached removed dependency is INPUT');
    require(
      (await rule.check(root)).isEmpty,
      'restored removed dependency clean',
    );

    final helper = File(
      '${root.path}/lib/core/screens/administration/admin_widgets.dart',
    );
    final originalHelper = await helper.readAsString();
    final helperUse = view(
      'void f() { const AdminGroup(); }',
      imports: '${sessionImport}import "admin_widgets.dart";\n',
    );
    await viewFile.writeAsString(helperUse);
    require((await rule.check(root)).isEmpty, 'cached helper clean');
    await helper.writeAsString(
      'export "../../services/administration_repository.dart";\n$originalHelper',
    );
    require(
      (await rule.check(root)).isNotEmpty,
      'cached export insertion fails',
    );
    await helper.writeAsString(originalHelper);
    require(
      (await rule.check(root)).isEmpty,
      'restored export namespace clean',
    );

    await put('tools/cached_profiles_part.dart', '''
part of '../lib/core/screens/administration/admin_profiles_page.dart';
Map<String,dynamic> protocol() => {'ok': true};
''');
    // A part directive must precede declarations; keep this valid Dart so the
    // result tests actual part/protocol ownership rather than syntax rejection.
    await viewFile.writeAsString(
      '$sessionImport\npart "${File('${root.path}/tools/cached_profiles_part.dart').uri}";\n$factory void f() {}',
    );
    require(
      (await rule.check(root)).isNotEmpty,
      'cached actual part insertion fails',
    );
    await viewFile.writeAsString(valid.first);
    require(
      (await rule.check(root)).isEmpty,
      'restored containing library clean',
    );

    final packageConfig = File('${root.path}/.dart_tool/package_config.json');
    final originalConfig = await packageConfig.readAsString();
    await put('lib/fake_flutter/material.dart', 'class Icon {}');
    final installedUse = view(
      'void f(Icon value) {}',
      imports:
          '${sessionImport}import "package:flutter/material.dart" show Icon;\n',
    );
    await viewFile.writeAsString(installedUse);
    require(
      (await rule.check(root)).isEmpty,
      'cached installed presentation clean',
    );
    final configData = jsonDecode(originalConfig) as Map<String, dynamic>;
    final flutter = (configData['packages'] as List).cast<Map>().singleWhere(
      (value) => value['name'] == 'flutter',
    );
    flutter['rootUri'] = '../lib/fake_flutter/';
    flutter['packageUri'] = '';
    await packageConfig.writeAsString(jsonEncode(configData));
    require(
      (await rule.check(root)).isNotEmpty,
      'cached package masquerade fails',
    );
    await packageConfig.writeAsString(originalConfig);
    require((await rule.check(root)).isEmpty, 'restored package config clean');

    // Analysis options are part of cache provenance. Undefined invocation stays
    // INPUT before and after a same-path options change and cannot reuse clean.
    await viewFile.writeAsString(valid.first);
    await put(
      'analysis_options.yaml',
      'analyzer:\n  strong-mode:\n    implicit-casts: false\n',
    );
    require((await rule.check(root)).isEmpty, 'cached options change clean');
    await viewFile.writeAsString(view('void f() { MissingType(); }'));
    var optionsInput = false;
    try {
      await rule.check(root);
    } on FormatException {
      optionsInput = true;
    }
    require(optionsInput, 'cached options semantic failure INPUT');
    await File('${root.path}/analysis_options.yaml').delete();
    await viewFile.writeAsString(valid.first);
    final concurrent = await Future.wait([rule.check(root), rule.check(root)]);
    require(
      concurrent.every((findings) => findings.isEmpty),
      'concurrent cache stores clean',
    );

    await viewFile.writeAsString(valid.first);
    var invalidSdk = false;
    try {
      await rule.check(root, sdkPath: '${root.path}/missing-sdk');
    } on FormatException {
      invalidSdk = true;
    }
    require(invalidSdk, 'invalid SDK refuses even clean input');
    final binary = args.isEmpty ? '${root.path}/guard' : args.last;
    if (args.isEmpty) {
      final compile = await runProofProcess(proofDartExecutable, [
        'compile',
        'exe',
        File(
          'tools/architecture/rules/profiles_management_view.dart',
        ).absolute.path,
        '-o',
        binary,
      ]);
      require(
        compile.exitCode == 0,
        'compile: ${compile.stdout} ${compile.stderr}',
      );
    }
    for (final example in [
      (invalid.first, 1),
      (valid.first, 0),
      (input.first, 2),
      (invalid[4], 1),
      (valid[8], 0),
      (input[4], 2),
      (input.last, 2),
      (input[input.length - 2], 2),
      (invalid[previousInvalid], 1),
      (invalid[previousInvalid + 3], 1),
      (invalid[previousInvalid + 5], 1),
      (valid.last, 0),
    ]) {
      await viewFile.writeAsString(example.$1);
      for (final command in [
        (
          proofDartExecutable,
          [
            'run',
            'tools/architecture/rules/profiles_management_view.dart',
            '--root',
            root.path,
          ],
        ),
        (binary, ['--root', root.path]),
      ]) {
        final result = await runProofProcess(command.$1, command.$2);
        require(
          result.exitCode == example.$2,
          'CLI expected ${example.$2}: ${result.stdout} ${result.stderr}',
        );
        if (example.$2 == 1) {
          require('${result.stdout}'.contains(rule.id), 'CLI id');
        }
      }
    }
    // A pure-Dart miniature library remains supported with an explicit SDK
    // and no package configuration. Absence is cache provenance, not a new
    // requirement imposed by caching on otherwise valid predecessor inputs.
    await viewFile.writeAsString(valid.first);
    await packageConfig.rename('${packageConfig.path}.held');
    final explicitSdk = File(proofDartExecutable).parent.parent.path;
    require(
      (await rule.check(root, sdkPath: explicitSdk)).isEmpty,
      'explicit SDK without package config clean',
    );
    for (final command in [
      (
        proofDartExecutable,
        [
          'run',
          'tools/architecture/rules/profiles_management_view.dart',
          '--root',
          root.path,
          '--sdk',
          explicitSdk,
        ],
      ),
      (binary, ['--root', root.path, '--sdk', explicitSdk]),
    ]) {
      final result = await runProofProcess(command.$1, command.$2);
      require(
        result.exitCode == 0,
        'CLI explicit SDK/no package config: ${result.stdout} ${result.stderr}',
      );
    }
    await File('${packageConfig.path}.held').rename(packageConfig.path);
    for (final command in [
      (
        proofDartExecutable,
        [
          'run',
          'tools/architecture/rules/profiles_management_view.dart',
          '--root',
          root.path,
          '--sdk',
          '${root.path}/missing-sdk',
        ],
      ),
      (binary, ['--root', root.path, '--sdk', '${root.path}/missing-sdk']),
    ]) {
      final result = await runProofProcess(command.$1, command.$2);
      require(result.exitCode == 2, 'CLI invalid SDK must be INPUT2');
    }
    stdout.writeln(
      'PASS ${invalid.length + valid.length + input.length} '
      'profiles-view fixtures plus eight cache mutation/concurrency scenarios and explicit-SDK/no-config CLI0; source/fresh-AOT CLI 1/0/2 and invalid SDK2',
    );
  } finally {
    await root.delete(recursive: true);
  }
}
