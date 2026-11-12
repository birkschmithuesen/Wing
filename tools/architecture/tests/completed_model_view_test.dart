import 'dart:io';

import '../rules/completed_model_view.dart' as rule;
import '../proof_process.dart';

void expect(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main(List<String> args) =>
    withProofProcesses(() => _proofMain(args));

Future<void> _proofMain(List<String> args) async {
  if (args.isNotEmpty && (args.length != 2 || args.first != '--compiled')) {
    throw const FormatException('Use [--compiled PATH]');
  }
  final root = await Directory.systemTemp.createTemp(
    'wing-completed-model-view-',
  );
  try {
    final config = File('${root.path}/.dart_tool/package_config.json');
    await config.parent.create(recursive: true);
    await config.writeAsString(
      File('.dart_tool/package_config.json').readAsStringSync(),
    );
    for (final entry in {
      'lib/core/services/profile_gateway.dart': '''
class ProfileGateway {
  Map<String, dynamic> read(String path) => {};
  void post(String path) {}
  void requireProfile() {}
}
''',
      'lib/core/services/administration_repository.dart': '''
part 'repository_calls.dart';
class ProfileAdministration { void write() {} void config() {} void saveSettings() {} }
''',
      'lib/core/services/repository_calls.dart': '''
part of 'administration_repository.dart';
class AdministrationRepository {
 final void Function() request = () {};
 final void Function() settingsWrite = () {};
 final void Function() ownedMutation = () {};
}
class UiCallbacks { final void Function() ownedMutation = () {}; }
''',
      'lib/core/services/connection_manager.dart': '''
class DashboardClient { void apiGet() {} }
''',
      'lib/core/services/ws_client.dart': '''
class WsClient { void call() {} }
''',
      'lib/core/services/profile_diagnostics_controller.dart': '''
class ProfileDiagnosticsController {
 void check() {}
 void invalidate() {}
 void updateModel(Object? model) {}
 void updateGateway(Object? gateway) {}
 void restore(Object? snapshot) {}
 Map<String, Object?> snapshot() => {};
 bool get checking => false;
 void addListener(void Function() listener) {}
 void removeListener(void Function() listener) {}
 void dispose() {}
}
''',
      'lib/core/services/diagnostics_barrel.dart':
          "export 'profile_diagnostics_controller.dart';\n",
      'lib/core/models/model_choice.dart': '''
class ConfiguredModel { static void fromInfo(Map<String, dynamic> response) {} }
''',
      'lib/core/models/model_catalog.dart': '''
class ModelCatalog { static void fromOptions(Map<String, dynamic> response) {} }
''',
      'lib/core/models/fallback_model.dart': '''
class FallbackModel {
  final String label;
  FallbackModel(this.label);
  static List<FallbackModel> fromConfig(Map<String, dynamic> config) => [];
}
''',
      'lib/core/models/profile_model_defaults.dart': '''
class HelperModelAssignment { static void fromResponse(Map<String, dynamic> response) {} }
class ModelDefaultsObservation { static void fromResponses(Map<String, dynamic> response) {} }
class ModelProviderAccess { static void fromResponse(Map<String, dynamic> response) {} }
''',
      'lib/core/services/gateway_barrel.dart':
          "export 'profile_gateway.dart';\n",
      'lib/core/services/repository_barrel.dart':
          "export 'administration_repository.dart';\n",
    }.entries) {
      final file = File('${root.path}/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
    for (final path in rule.completedViews.skip(1)) {
      final other = File('${root.path}/$path');
      await other.parent.create(recursive: true);
      await other.writeAsString('void render() {}');
    }
    final view = File('${root.path}/${rule.completedViews.first}');
    await view.parent.create(recursive: true);
    const gateway = "import '../services/profile_gateway.dart';\n";
    const repository = "import '../services/administration_repository.dart';\n";
    final invalid = <String>[
      '${gateway}void f(ProfileGateway gateway) { gateway.read("model/info"); }',
      '${gateway}void f(ProfileGateway gateway) { final alias = gateway; alias.post("model/set"); }',
      '${gateway}void f(ProfileGateway gateway) { gateway..requireProfile()..post("model/set"); }',
      '${gateway}void f(ProfileGateway gateway) { final request = gateway.read; request("model/info"); }',
      "import '../services/gateway_barrel.dart' as api;\n"
          'typedef Link = api.ProfileGateway; void f(Link gateway) { gateway.read("model/info"); }',
      "import '../models/model_catalog.dart' as model;\n"
          'void f(Map<String, dynamic> value) { final parse = model.ModelCatalog.fromOptions; parse(value); }',
      "import '../models/fallback_model.dart' as model;\n"
          'void f(Map<String, dynamic> value) { final parse = model.FallbackModel.fromConfig; parse(value); }',
      "import '../models/model_choice.dart' as model;\n"
          'void f(Map<String, dynamic> value) { final parse = model.ConfiguredModel.fromInfo; parse(value); }',
      "import '../models/profile_model_defaults.dart' as model;\n"
          'void f(Map<String, dynamic> value) { model.HelperModelAssignment.fromResponse(value); }',
      "import '../models/profile_model_defaults.dart' as model;\n"
          'void f(Map<String, dynamic> value) { model.ModelDefaultsObservation.fromResponses(value); }',
      "import '../models/profile_model_defaults.dart' as model;\n"
          'void f(Map<String, dynamic> value) { model.ModelProviderAccess.fromResponse(value); }',
      'Object? f(Map<String, dynamic> value) => value["model"];',
      r'Object? f(Map<String, Object?> value) => value["\u006dodel"];',
      'typedef Wire = Map<String, dynamic>; Object? f(Wire value) => value["providers"];',
      '${repository}void f(AdministrationRepository repo) { repo.request(); }',
      '${repository}void f(AdministrationRepository repo) { repo.settingsWrite(); }',
      '${repository}void f(AdministrationRepository repo) { repo.ownedMutation(); }',
      '${repository}void f(AdministrationRepository repo) { final alias = repo; alias..request()..ownedMutation(); }',
      '${repository}void f(AdministrationRepository repo) { final send = repo.settingsWrite; send(); }',
      "import '../services/repository_barrel.dart' as api;\n"
          'typedef Repo = api.AdministrationRepository; void f(Repo repo) { final send = repo.request; send(); }',
      '${repository}void f(AdministrationRepository repo) { (repo.ownedMutation).call(); }',
      '${repository}void consume(void Function() callback) {} void f(AdministrationRepository repo) { consume(repo.ownedMutation); }',
      '${repository}extension ViewAdapter on AdministrationRepository { void Function() captured() => ownedMutation; }',
      '${repository}class View extends AdministrationRepository { late final selected = request; }',
    ];
    const diagnostics =
        "import '../services/profile_diagnostics_controller.dart';\n";
    invalid.addAll([
      for (final command in [
        'check',
        'invalidate',
        'updateModel',
        'updateGateway',
        'restore',
      ])
        '${diagnostics}void f(ProfileDiagnosticsController checks) { checks.$command${{'updateModel', 'updateGateway', 'restore'}.contains(command) ? '(null)' : '()'}; }',
      "import '../services/diagnostics_barrel.dart' as api;\n"
          'typedef Checks = api.ProfileDiagnosticsController; void f(Checks checks) { final alias = checks; final run = alias.check; run(); alias..invalidate(); }',
      '${diagnostics}class View extends ProfileDiagnosticsController { late final captured = invalidate; }',
    ]);
    for (var i = 0; i < invalid.length; i++) {
      await view.writeAsString(invalid[i]);
      final findings = await rule.check(root);
      expect(
        findings.isNotEmpty && findings.every((value) => value.id == rule.id),
        'invalid fixture $i',
      );
      expect(
        findings.first.file == rule.completedViews.first &&
            findings.first.line > 0,
        'diagnostic location $i',
      );
    }
    final valid = <String>[
      '${gateway}void f(ProfileGateway gateway) { final label = "gateway.read(); value[model]"; /* gateway.post() */ }',
      'class Ui { void read() {} void call() {} } void f(Ui ui) { ui..read()..call(); }',
      'String? f(Map<String, String> labels) => labels["model"];',
      'bool? f(Map<String, bool> visualFilters) => visualFilters["providers"];',
      'Object? f(Map<String, Object?> decorations) => decorations["padding"];',
      "import '../models/fallback_model.dart';\n"
          'List<String> render(List<FallbackModel> rows) => rows.map((row) => row.label).toList();',
      'class Edit { void load() {} void save() {} } void f(Edit edit) { edit..load()..save(); }',
      'class Ui { final void Function() request = () {}; final void Function() settingsWrite = () {}; final void Function() ownedMutation = () {}; } '
          'void f(Ui ui) { final alias = ui; alias..request()..settingsWrite(); final send = alias.ownedMutation; send(); }',
      '${repository}void f(AdministrationRepository repo) { /* repo.ownedMutation() */ final label = "request settingsWrite"; }',
      "import '../services/repository_barrel.dart' as ui;\n"
          'typedef Callbacks = ui.UiCallbacks; void f(Callbacks callbacks) { final alias = callbacks; alias..ownedMutation(); final selected = alias.ownedMutation; selected(); }',
      'void f(void Function() callback) { callback.call(); }',
    ];
    valid.addAll([
      '${diagnostics}Object render(ProfileDiagnosticsController checks) { checks.addListener(() {}); checks.removeListener(() {}); checks.dispose(); final busy = checks.checking; return checks.snapshot(); }',
      'class ProfileDiagnosticsController { void check() {} void invalidate() {} void updateModel(Object? value) {} void updateGateway(Object? value) {} void restore(Object? value) {} } '
          'void render(ProfileDiagnosticsController ui) { final callback = ui.invalidate; callback(); ui..check()..updateModel(null)..updateGateway(null)..restore(null); }',
    ]);
    for (var i = 0; i < valid.length; i++) {
      await view.writeAsString(valid[i]);
      expect((await rule.check(root)).isEmpty, 'valid fixture $i');
    }
    final inputErrors = <String>[
      'void f() {',
      r'void f(dynamic gateway) { gateway.\u0072ead(); }',
      '${gateway}void f(dynamic gateway) { gateway.read("model/info"); }',
      'Object? f(dynamic value) => value["model"];',
      "import '../services/profile_gateway.dart' if (dart.library.io) '../services/gateway_barrel.dart'; void f() {}",
      "part 'extra.dart'; void f() {}",
    ];
    inputErrors.add('void f(dynamic checks) { checks.invalidate(); }');
    for (var i = 0; i < inputErrors.length; i++) {
      await view.writeAsString(inputErrors[i]);
      var rejected = false;
      try {
        await rule.check(root);
      } on FormatException {
        rejected = true;
      }
      expect(rejected, 'unsupported input $i must fail closed');
    }
    final executable = File(
      'tools/architecture/rules/completed_model_view.dart',
    ).absolute.path;
    final compiled = args.isEmpty ? '${root.path}/guard' : args.last;
    if (args.isEmpty) {
      final compilation = await runProofProcess(proofDartExecutable, [
        'compile',
        'exe',
        executable,
        '-o',
        compiled,
      ]);
      expect(
        compilation.exitCode == 0,
        'guard compilation failed: ${compilation.stderr}',
      );
    }
    for (final example in [
      (invalid.first, 1),
      (valid[10], 0),
      (inputErrors.first, 2),
    ]) {
      await view.writeAsString(example.$1);
      final result = await runProofProcess(proofDartExecutable, [
        'run',
        'tools/architecture/rules/completed_model_view.dart',
        '--root',
        root.path,
      ]);
      expect(
        result.exitCode == example.$2,
        'CLI ${example.$2}: ${result.stdout}\n${result.stderr}',
      );
      if (example.$2 == 1) {
        expect(
          result.stdout.toString().contains(
            '${rule.completedViews.first}:2 [${rule.id}]',
          ),
          'actual CLI location',
        );
      }
      if (example.$2 == 2) {
        expect(
          result.stderr.toString().contains('[${rule.id} INPUT]'),
          'actual CLI input error',
        );
      }
    }
    // Both compiled verdicts require resolution; a clean syntax prefilter does
    // not establish that the binary can find a real SDK outside dart-sdk/bin.
    for (final example in [(invalid[14], 1), (valid[7], 0)]) {
      await view.writeAsString(example.$1);
      final result = await runProofProcess(compiled, ['--root', root.path]);
      expect(
        result.exitCode == example.$2,
        'compiled CLI ${example.$2}: ${result.stdout}\n${result.stderr}',
      );
      if (example.$2 == 1) {
        expect(
          result.stdout.toString().contains(
            '${rule.completedViews.first}:2 [${rule.id}]',
          ),
          'compiled diagnostic location',
        );
      }
    }
    await view.writeAsString('void render() {}');
    final health = File(
      '${root.path}/lib/core/screens/administration/admin_health_page.dart',
    );
    final healthCases = [
      (
        "import '../../services/profile_diagnostics_controller.dart';\n"
            'void fixAccess(ProfileDiagnosticsController checks) { checks.invalidate(); }',
        1,
      ),
      (
        "import '../../services/profile_diagnostics_controller.dart';\n"
            'Object render(ProfileDiagnosticsController checks, void Function() onReviewAccess) { final callback = onReviewAccess; callback(); return checks.snapshot(); }',
        0,
      ),
      ('void fixAccess(dynamic checks) { checks.invalidate(); }', 2),
    ];
    for (final example in healthCases) {
      await health.writeAsString(example.$1);
      for (final command in [
        [proofDartExecutable, 'run', executable],
        [compiled],
      ]) {
        final result = await runProofProcess(command.first, [
          ...command.skip(1),
          '--root',
          root.path,
        ]);
        expect(
          result.exitCode == example.$2,
          'Health CLI ${example.$2}: ${result.stdout}\n${result.stderr}',
        );
        if (example.$2 == 1) {
          expect(
            '${result.stdout}'.contains(
              'lib/core/screens/administration/admin_health_page.dart:2 [${rule.id}]',
            ),
            'Health canonical invalidate diagnostic',
          );
        }
        if (example.$2 == 2) {
          expect(
            '${result.stderr}'.contains('[${rule.id} INPUT]'),
            'Health unknown command input',
          );
        }
      }
    }
    await health.writeAsString('void render() {}');
    await view.writeAsString(invalid[14]);
    await config.delete();
    final missingSdk = await runProofProcess(compiled, ['--root', root.path]);
    expect(
      missingSdk.exitCode == 2 &&
          '${missingSdk.stderr}'.contains('[${rule.id} INPUT]'),
      'compiled missing SDK must fail input',
    );
    stdout.writeln(
      '${rule.id}: ${invalid.length + valid.length + inputErrors.length + 3 + healthCases.length} fixtures and source/compiled CLI 1/0/2 passed',
    );
  } finally {
    await root.delete(recursive: true);
  }
}
