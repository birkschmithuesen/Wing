import 'dart:io';

import '../rules/completed_setup_view.dart' as rule;
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
  final root = await Directory.systemTemp.createTemp('wing-setup-view-');
  try {
    final config = File('${root.path}/.dart_tool/package_config.json');
    await config.parent.create(recursive: true);
    await config.writeAsString(
      File('.dart_tool/package_config.json').readAsStringSync(),
    );
    for (final entry in {
      'lib/core/services/connection_manager.dart':
          'class ConnectionManager { ConnectionManager(); void getConnections() {} void saveConnection() {} void updateDashboardAuth() {} }',
      'lib/core/services/hermes_cloud.dart': '''
class HermesCloud { static const portal = 'https://example.invalid'; void discover() {} void signIn() {} void cancel() {} void close() {} }
class CloudDiscovery { CloudDiscovery(); static void parse() {} }
class CloudInstance { CloudInstance(); }
''',
      'lib/core/services/connection_setup_probe.dart': '''
class ConnectionSetupProbe { ConnectionSetupProbe(); void check() {} void cancel() {} void dispose() {} }
class DashboardConnectionProbe { DashboardConnectionProbe(); }
''',
      'lib/core/services/dashboard_oauth_session.dart':
          'class DashboardOAuthSession { DashboardOAuthSession(); }',
      'lib/core/services/connection_access.dart':
          'class ConnectionAccess { ConnectionAccess(); }',
      'lib/core/models/connection_address.dart':
          'class ConnectionAddress { ConnectionAddress(); static void parse() {} }',
      'lib/core/models/connection.dart': '''
part 'connection_part.dart';
class SavedConnection { SavedConnection(); SavedConnection.named(); void copyWith() {} static void joinBaseUrl() {} }
''',
      'lib/core/models/connection_part.dart':
          "part of 'connection.dart'; void resolveGatewayHeaderUpdate() {}",
      'lib/core/services/conditional_barrel.dart':
          "export 'hermes_cloud.dart' if (dart.library.io) 'connection_setup_probe.dart';",
      'lib/core/services/cycle_a.dart': "export 'cycle_b.dart';",
      'lib/core/services/cycle_b.dart':
          "export 'cycle_a.dart'; export 'hermes_cloud.dart' show HermesCloud; export 'cycle_ui.dart' show Ui; export 'cycle_alias.dart' show Selected;",
      'lib/core/services/cycle_ui.dart':
          'class Ui { void signIn() {} void cancel() {} }',
      'lib/core/services/cycle_alias.dart':
          "import 'hermes_cloud.dart'; typedef Selected = HermesCloud;",
      'lib/core/services/variable_collision.dart':
          "final HermesCloud = 'unrelated';",
      'lib/core/services/type_collision.dart': 'mixin HermesCloud {}',
      'lib/core/services/hide_cloud.dart':
          "export 'hermes_cloud.dart' hide HermesCloud;",
      'lib/core/services/setup_barrel.dart':
          "export 'hermes_cloud.dart'; export 'connection_setup_probe.dart'; export '../models/connection.dart';",
    }.entries) {
      final file = File('${root.path}/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
    final view = File('${root.path}/${rule.completedView}');
    await view.parent.create(recursive: true);
    const cloud = "import '../services/hermes_cloud.dart';\n";
    const probe = "import '../services/connection_setup_probe.dart';\n";
    const connection = "import '../models/connection.dart';\n";
    final invalid = <String>[
      "import '../services/connection_manager.dart'; void f(ConnectionManager manager) { manager.saveConnection(); }",
      "import '../services/connection_manager.dart' as data; typedef Store = data.ConnectionManager; void f(Store manager) { final callback = manager.updateDashboardAuth; callback(); }",
      "import '../services/connection_manager.dart'; void f() { ConnectionManager(); }",
      '${cloud}void f(HermesCloud value) { value.discover(); }',
      '${cloud}void f(HermesCloud value) { final alias = value; alias..signIn()..cancel(); }',
      '${cloud}void f(HermesCloud value) { final selected = value.close; selected(); }',
      "import '../services/setup_barrel.dart' as api; typedef Cloud = api.HermesCloud; void f(Cloud value) { value.signIn(); }",
      '${cloud}class View extends HermesCloud { late final selected = discover; }',
      '${cloud}extension View on HermesCloud { void Function() selected() => signIn; }',
      '${probe}void f(ConnectionSetupProbe value) { value.check(); }',
      '${probe}void f(ConnectionSetupProbe value) { final selected = value.cancel; selected(); }',
      '${probe}void f() { ConnectionSetupProbe(); }',
      '${probe}void f() { final selected = DashboardConnectionProbe.new; selected(); }',
      '${connection}void f() { SavedConnection(); }',
      '${connection}void f() { final selected = SavedConnection.named; selected(); }',
      '${connection}typedef Saved = SavedConnection; void f() { Saved(); }',
      '${connection}void f(SavedConnection value) { value.copyWith(); }',
      '${connection}void f() { final selected = SavedConnection.joinBaseUrl; selected(); }',
      '${connection}void f() { final selected = resolveGatewayHeaderUpdate; selected(); }',
      "import '../models/connection_address.dart' as model; void f() { model.ConnectionAddress.parse(); }",
      "import '../services/connection_access.dart'; void f() { ConnectionAccess(); }",
      "import '../services/dashboard_oauth_session.dart'; void f() { DashboardOAuthSession(); }",
      '${cloud}void f() { CloudDiscovery.parse(); }',
      '${cloud}void f() { CloudInstance(); }',
      // Candidate filters must not bind prefixed types or local shadows to UI.
      "import '../services/connection_manager.dart' as data; class View { late data.ConnectionManager owner; void f() { owner.saveConnection(); } }",
      "${probe}class Ui { void check() {} } class View { late Ui value; void f(ConnectionSetupProbe value) { value.check(); } }",
      "${probe}class Ui { void check() {} } class View { late Ui value; void f(List<ConnectionSetupProbe> values) { for (final value in values) { value.check(); } } }",
      "${probe}class Ui { void check() {} } class View { late Ui value; void f(ConnectionSetupProbe input) { final (value,) = (input,); value.check(); } }",
      "${cloud}class Derived extends HermesCloud {} class View { late Derived owner; void f() { owner.signIn(); } }",
      "import '../services/setup_barrel.dart' as api; typedef Selected = api.HermesCloud; Selected Function() f() => Selected.new;",
      "${probe}class View { late ConnectionSetupProbe value; void f() { value..check()..cancel(); } }",
      "${cloud}class View { late HermesCloud value; void f() { final callback = value.signIn; callback(); } }",
      '${cloud}void f() { final create = HermesCloud.new; create(); }',
      "import '../services/cycle_a.dart' as data; void f(data.HermesCloud value) { value.signIn(); }",
      "${cloud}class Ui { static const portal = 'https://example.invalid'; } class View { late HermesCloud Ui; void f() { Ui.signIn(); } }",
      "import '../services/cycle_a.dart' as data; class View { late data.Selected value; void f() { value.signIn(); } }",
      "${cloud}class Ui { void signIn() {} } class View<Ui extends HermesCloud> { late Ui value; void f() { value.signIn(); } }",
    ];
    for (var index = 0; index < invalid.length; index++) {
      await view.writeAsString(invalid[index]);
      final findings = await rule.check(root);
      expect(
        findings.isNotEmpty &&
            findings.every(
              (value) =>
                  value.id == rule.id &&
                  value.file == rule.completedView &&
                  value.line > 0,
            ),
        'invalid $index',
      );
    }
    final valid = <String>[
      '${cloud}void f() { /* HermesCloud().discover() */ final text = "SavedConnection()"; }',
      'class Ui { void discover() {} void signIn() {} void check() {} } void f(Ui value) { value..discover()..signIn()..check(); }',
      'class SavedConnection { SavedConnection(); void copyWith() {} } void f() { SavedConnection().copyWith(); }',
      'class ConnectionAddress { static void parse() {} } void f() { ConnectionAddress.parse(); }',
      'void resolveGatewayHeaderUpdate() {} void f() { resolveGatewayHeaderUpdate(); }',
      'class Session { void check() {} void dispose() {} } void f(Session session) { final command = session.check; command(); session.dispose(); }',
      'class Draft { Draft(); } void Function() f(void Function() callback) => callback.call;',
      'String? render(Map<String, String> labels) => labels["dashboardUrl"];',
      'class Ui { void saveConnection() {} } void f(Ui ui) { ui.saveConnection(); }',
      'class Ui { void close() {} } extension View on Ui { void Function() get command => close; }',
      'class Ui { void check() {} } class View { late Ui value; void f() { value.check(); } }',
      'class Ui { void dispose() {} } class View { late Ui first; late Ui second; void f() { for (final value in [first, second]) { value.dispose(); } } }',
      '${cloud}class Ui extends HermesCloud { @override void signIn() {} } class View { late Ui value; void f() { value.signIn(); } }',
      'class Ui {} extension HermesCloud on Ui { void signIn() {} } void f(Ui value) { value.signIn(); }',
      'Uri f(String value) => Uri.parse(value);',
      '${cloud}String f() => HermesCloud.portal;',
      "class HermesCloud { static const portal = 'https://example.invalid'; } String f() => HermesCloud.portal;",
      "import '../services/hide_cloud.dart'; class HermesCloud { static const portal = 'https://example.invalid'; } String f() => HermesCloud.portal;",
      "import '../services/cycle_a.dart'; class Ui { void signIn() {} } class View { late Ui value; void f() { value.signIn(); } }",
      "import '../services/cycle_a.dart' as data; class View { late data.Ui value; void f() { value.signIn(); value.cancel(); value.signIn(); } }",
      "${cloud}import '../services/variable_collision.dart' hide HermesCloud; String f() => HermesCloud.portal;",
      'class Ui { void signIn() {} } class View<T> { late Ui value; void f() { value.signIn(); } }',
    ];
    for (var index = 0; index < valid.length; index++) {
      await view.writeAsString(valid[index]);
      expect((await rule.check(root)).isEmpty, 'valid $index');
    }
    final badInput = <String>[
      'void f() {',
      'void f() { SavedConnection(); }',
      'void f() { final construct = SavedConnection.new; }',
      'void f(dynamic value) { value.signIn(); }',
      r'void f(dynamic value) { value.\u0073ignIn(); }',
      "import '../services/hermes_cloud.dart' if (dart.library.io) '../services/setup_barrel.dart'; void f() {}",
      "part 'extra.dart'; void f() {}",
      "import '../services/absent.dart'; void f() {}",
      'class Ui { void check() {} } class View { late Ui value; void f(dynamic input) { final (value,) = (input,); value.check(); } }',
      'class Ui { void check() {} } class View { late Ui value; void f(List<dynamic> values) { for (final value in values) { value.check(); } } }',
      "import '../services/conditional_barrel.dart'; void f() {}",
      'String f() => HermesCloud.portal;',
      "${cloud}import '../services/variable_collision.dart'; String f() => HermesCloud.portal;",
      "${cloud}import '../services/type_collision.dart'; String f() => HermesCloud.portal;",
      "class HermesCloud { static const portal = 'https://example.invalid'; static String get portal => ''; } String f() => HermesCloud.portal;",
    ];
    for (var index = 0; index < badInput.length; index++) {
      await view.writeAsString(badInput[index]);
      var rejected = false;
      try {
        await rule.check(root);
      } on FormatException {
        rejected = true;
      }
      expect(rejected, 'input $index');
    }
    final binary = args.isEmpty ? '${root.path}/guard' : args.last;
    if (args.isEmpty) {
      final compile = await runProofProcess(proofDartExecutable, [
        'compile',
        'exe',
        File(
          'tools/architecture/rules/completed_setup_view.dart',
        ).absolute.path,
        '-o',
        binary,
      ]);
      expect(compile.exitCode == 0, 'compile: ${compile.stderr}');
    }
    // All detector payloads are exercised above. These representatives prove
    // the shared CLI's three exits without repeating its startup per feature.
    final exercisedCliExits = <String, Set<int>>{'source': {}, 'aot': {}};
    for (final example in [
      (invalid.first, 1),
      (valid[14], 0), // Preserve the original implicit dart:core Uri CLI case.
      (badInput.first, 2),
    ]) {
      await view.writeAsString(example.$1);
      for (final command in [
        (
          proofDartExecutable,
          [
            'run',
            'tools/architecture/rules/completed_setup_view.dart',
            '--root',
            root.path,
          ],
          'source',
        ),
        (binary, ['--root', root.path], 'aot'),
      ]) {
        final result = await runProofProcess(command.$1, command.$2);
        expect(
          result.exitCode == example.$2,
          'CLI ${example.$2}: ${result.stdout} ${result.stderr}',
        );
        final diagnostics = '${result.stdout}'
            .split('\n')
            .where((line) => line.contains('[${rule.id}]'))
            .toList();
        if (example.$2 == 1) {
          expect(
            diagnostics.length == 1 &&
                diagnostics.single.startsWith(
                  '${rule.completedView}:1 [${rule.id}]',
                ) &&
                diagnostics.single.endsWith(
                  '(setup-owner:${example.$1.indexOf('saveConnection')})',
                ),
            'CLI exact canonical operation identity/location',
          );
        } else if (example.$2 == 0) {
          expect(
            diagnostics.isEmpty &&
                !'${result.stderr}'.contains('[${rule.id} INPUT]'),
            'valid CLI must not emit a boundary or input diagnostic',
          );
        } else {
          expect(
            '${result.stderr}'.contains('[${rule.id} INPUT]'),
            'malformed CLI input must emit the typed input diagnostic',
          );
        }
        expect(
          exercisedCliExits[command.$3]!.add(result.exitCode),
          'duplicate CLI exit representative for ${command.$3}',
        );
      }
    }
    expect(
      exercisedCliExits.values.every(
        (exits) => exits.length == 3 && exits.containsAll({0, 1, 2}),
      ),
      'source and AOT must each prove all three CLI exits',
    );
    // This boundary's no-candidate path intentionally delegates unrelated
    // semantic errors to mandatory standard SDK analysis. Prove BOTH verdicts.
    const noncandidate = "int f() => 'not an int';";
    await view.writeAsString(noncandidate);
    expect((await rule.check(root)).isEmpty, 'noncandidate boundary property');
    final analysis = await runProofProcess(proofDartExecutable, [
      'analyze',
      view.path,
    ]);
    expect(
      analysis.exitCode != 0 &&
          '${analysis.stdout}'.contains('return_of_invalid_type'),
      'standard SDK must reject noncandidate semantic error: '
      '${analysis.stdout} ${analysis.stderr}',
    );
    for (final command in [
      (
        proofDartExecutable,
        [
          'run',
          'tools/architecture/rules/completed_setup_view.dart',
          '--root',
          root.path,
        ],
      ),
      (binary, ['--root', root.path]),
    ]) {
      final result = await runProofProcess(command.$1, command.$2);
      expect(result.exitCode == 0, 'noncandidate CLI split ${result.stderr}');
      final invalidSdk = await runProofProcess(command.$1, [
        ...command.$2,
        '--sdk',
        '${root.path}/missing-sdk',
      ]);
      expect(
        invalidSdk.exitCode == 2 &&
            '${invalidSdk.stderr}'.contains('${rule.id} INPUT'),
        'invalid SDK remains unconditional: ${invalidSdk.stderr}',
      );
    }
    stdout.writeln(
      '${invalid.length + valid.length + badInput.length} setup-view fixtures + source/AOT CLI 1/0/2 PASS',
    );
  } finally {
    await root.delete(recursive: true);
  }
}
