import 'dart:io';

import '../rules/backup_owner_boundary.dart' as rule;
import '../proof_process.dart';

void require(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main(List<String> args) =>
    withProofProcesses(() => _proofMain(args));

Future<void> _proofMain(List<String> args) async {
  if (args.isNotEmpty && (args.length != 2 || args.first != '--compiled')) {
    throw const FormatException('Use [--compiled PATH]');
  }
  final root = await Directory.systemTemp.createTemp('wing-backup-owner-');
  try {
    final config = File('${root.path}/.dart_tool/package_config.json');
    await config.parent.create(recursive: true);
    await config.writeAsString(
      File('.dart_tool/package_config.json').readAsStringSync(),
    );
    Future<void> write(String path, String source) async {
      final file = File('${root.path}/$path');
      await file.parent.create(recursive: true);
      await file.writeAsString(source);
    }

    const cleanService =
        'class ConfigBackupService { void export() {} void import() {} }';
    const cleanPlatform =
        'class ConfigBackupIo { void pickBackupFile() {} void deliverExport() {} }';
    const cleanMain = '''
class HomeScreenState {
  void _showBackupConfig() {}
  void _showRestoreConfig() {}
}
''';
    const cleanSheet = '''
class _ExportPassphraseSheetState {}
class _ImportOptionsSheetState {}
''';
    await write('lib/core/services/config_backup.dart', '''
class ConfigBackupCodec { static void encode() {} static void decode() {} }
class ConfigBackup { ConfigBackup.fromJson(); void toJson() {} }
''');
    await write('lib/core/services/config_backup_io.dart', '''
class ConfigBackupIo { void pickBackupFile() {} void deliverExport() {} }
''');
    await write('lib/core/services/connection_manager.dart', '''
class ConnectionManager { String get prefs => ''; void importConnections() {} void loadConnectionsWithSecrets() {} void observe() {} }
''');
    await write('lib/core/services/app_preferences.dart', '''
class AppPreferences { void exportBackupSnapshot() {} void restoreBackupPatch() {} }
''');
    await write(
      'lib/core/services/device_preference.dart',
      'void saveDevicePreference() {}',
    );
    await write(
      'lib/core/services/backup_barrel.dart',
      "export 'config_backup.dart'; export 'config_backup_io.dart';",
    );

    await write(
      'lib/core/services/unrelated_session.dart',
      'class Session { void export() {} void decode() {} void clear() {} }',
    );
    await write(
      'lib/core/services/session_barrel.dart',
      "export 'unrelated_session.dart' show Session;",
    );
    await write(
      'lib/core/services/authority_factory.dart',
      "import 'connection_manager.dart'; ConnectionManager makeAuthority() => ConnectionManager();",
    );

    await write(
      'lib/core/services/storage_factory.dart',
      "import 'package:shared_preferences/shared_preferences.dart'; SharedPreferences createStorage() => throw StateError('fixture only');",
    );

    await write(
      'lib/core/services/json_factory.dart',
      "import 'dart:convert'; JsonCodec createCodec() => const JsonCodec();",
    );

    Future<void> fixture(String path, String text) async {
      await write(rule.service, cleanService);
      await write(rule.platform, cleanPlatform);
      await write(rule.mainView, cleanMain);
      await write(rule.sheetView, cleanSheet);
      await write(path, text);
    }

    String handler(String imports, String body) =>
        '''
$imports
class HomeScreenState {
  void _showBackupConfig() { $body }
  void _showRestoreConfig() {}
}
''';
    final invalid = <(String, String)>[
      (
        rule.service,
        "import 'package:shared_preferences/shared_preferences.dart'; class ConfigBackupService { SharedPreferences? storage; }",
      ),
      (
        rule.service,
        "import 'package:shared_preferences/shared_preferences.dart' as store; class ConfigBackupService { void f(store.SharedPreferences value) { final read = value.getString; read('x'); } }",
      ),
      (
        rule.service,
        "import 'connection_manager.dart'; class ConfigBackupService { void f(ConnectionManager manager) { final alias = manager; alias.prefs; } }",
      ),
      (
        rule.service,
        "import 'device_preference.dart' as storage; class ConfigBackupService { void f() { final write = storage.saveDevicePreference; write(); } }",
      ),
      (
        rule.mainView,
        handler(
          "import 'core/services/config_backup.dart';",
          'ConfigBackupCodec.decode();',
        ),
      ),
      (
        rule.mainView,
        handler(
          "import 'core/services/backup_barrel.dart' as codec;",
          'final decode = codec.ConfigBackupCodec.decode; decode();',
        ),
      ),
      (
        rule.mainView,
        handler(
          "import 'core/services/config_backup.dart';",
          'ConfigBackup.fromJson();',
        ),
      ),
      (
        rule.mainView,
        handler(
          "import 'core/services/config_backup_io.dart';",
          'final io = ConfigBackupIo(); final alias = io; alias..pickBackupFile()..deliverExport();',
        ),
      ),
      (
        rule.mainView,
        handler(
          "import 'core/services/app_preferences.dart';",
          'final owner = AppPreferences(); owner.restoreBackupPatch();',
        ),
      ),
      (
        rule.mainView,
        handler(
          "import 'core/services/config_backup_service.dart';",
          'final owner = ConfigBackupService(); owner.export();',
        ),
      ),
      (
        rule.sheetView,
        "import '../services/config_backup_io.dart'; class _ExportPassphraseSheetState extends ConfigBackupIo { void f() { final read = pickBackupFile; read(); } } class _ImportOptionsSheetState {}",
      ),
      (
        rule.sheetView,
        "import '../services/backup_barrel.dart' as data; typedef Codec = data.ConfigBackupCodec; class _ExportPassphraseSheetState { void f() { Codec.encode(); } } class _ImportOptionsSheetState {}",
      ),
      (
        rule.platform,
        "import 'package:shared_preferences/shared_preferences.dart'; class ConfigBackupIo { SharedPreferences? storage; }",
      ),
      (
        rule.platform,
        "import 'connection_manager.dart' as auth; class ConfigBackupIo { auth.ConnectionManager? manager; }",
      ),
      (
        rule.platform,
        "import 'app_preferences.dart'; class ConfigBackupIo { void f(AppPreferences owner) { final alias = owner; alias..exportBackupSnapshot()..restoreBackupPatch(); } }",
      ),
      (
        rule.platform,
        "import 'config_backup_service.dart'; class ConfigBackupIo { void f() { final create = ConfigBackupService.new; create(); } }",
      ),
      (
        rule.platform,
        "import 'app_preferences.dart'; class ConfigBackupIo extends AppPreferences { void f() { final restore = restoreBackupPatch; restore(); } }",
      ),
      (
        rule.platform,
        "import 'device_preference.dart' as raw; class ConfigBackupIo { void f() { final save = raw.saveDevicePreference; save(); } }",
      ),
      (
        rule.mainView,
        handler(
          "import 'dart:convert' as wire;",
          'final read = wire.jsonDecode; read("{}");',
        ),
      ),
      (
        rule.sheetView,
        "import 'dart:convert' as wire; class _ExportPassphraseSheetState { void f() { wire.jsonEncode({}); } } class _ImportOptionsSheetState {}",
      ),
      (
        rule.mainView,
        handler(
          "import 'dart:convert'; typedef Wire = JsonCodec;",
          'final wire = Wire(); wire.decode("{}");',
        ),
      ),
      (
        rule.mainView,
        "import 'core/services/unrelated_session.dart'; import 'core/services/config_backup_service.dart'; class HomeScreenState { final Session session = Session(); void _showBackupConfig() { final session = ConfigBackupService(); session.export(); } void _showRestoreConfig() {} }",
      ),
      (
        rule.mainView,
        "import 'core/services/unrelated_session.dart'; import 'core/services/config_backup_service.dart'; class HomeScreenState { final Session session = Session(); void _showBackupConfig() { void invoke(ConfigBackupService session) { session.export(); } invoke(ConfigBackupService()); } void _showRestoreConfig() {} }",
      ),
      (
        rule.mainView,
        "import 'core/services/unrelated_session.dart'; import 'core/services/config_backup_service.dart'; class HomeScreenState { final Session session = Session(); void _showBackupConfig() { for (final session in [ConfigBackupService()]) { session.export(); } } void _showRestoreConfig() {} }",
      ),
      (
        rule.mainView,
        "import 'core/services/unrelated_session.dart'; import 'core/services/config_backup_service.dart'; class HomeScreenState { final Session session = Session(); void _showBackupConfig() { final (session,) = (ConfigBackupService(),); session.export(); } void _showRestoreConfig() {} }",
      ),
      (
        rule.mainView,
        "import 'core/services/config_backup_service.dart'; class Base extends ConfigBackupService {} class HomeScreenState extends Base { void _showBackupConfig() { final invoke = () => export(); invoke(); } void _showRestoreConfig() {} }",
      ),
      (
        rule.mainView,
        "import 'core/services/config_backup_service.dart' as data; typedef Owner = data.ConfigBackupService; class HomeScreenState { final Owner session = Owner(); void _showBackupConfig() { session.export(); } void _showRestoreConfig() {} }",
      ),
      (
        rule.mainView,
        "import 'core/services/config_backup_service.dart'; class Base { void export() {} } class HomeScreenState extends Base { final ConfigBackupService session = ConfigBackupService(); void _showBackupConfig() { session.export(); } void _showRestoreConfig() {} }",
      ),
      (
        rule.sheetView,
        "import 'dart:convert'; class _ExportPassphraseSheetState { final JsonCodec codec = JsonCodec(); void f() { codec.decode('{}'); } } class _ImportOptionsSheetState {}",
      ),
      (
        rule.platform,
        "import 'authority_factory.dart'; class ConfigBackupIo { void f() { final owner = makeAuthority(); owner.observe(); } }",
      ),
      (
        rule.mainView,
        "import 'core/services/unrelated_session.dart'; import 'core/services/config_backup_service.dart'; class HomeScreenState { final Session session = Session(); void _showBackupConfig() { try { throw ConfigBackupService(); } on ConfigBackupService catch (session) { session.export(); } } void _showRestoreConfig() {} }",
      ),
      (
        rule.mainView,
        "import 'core/services/unrelated_session.dart'; import 'core/services/config_backup_service.dart'; class HomeScreenState<Session extends ConfigBackupService> { HomeScreenState(this.session); final Session session; void _showBackupConfig() { session.export(); } void _showRestoreConfig() {} }",
      ),
      (
        rule.service,
        "import 'storage_factory.dart'; class ConfigBackupService { Future<void> f() async { await createStorage().reload(); } }",
      ),
      (
        rule.sheetView,
        "import 'dart:convert'; class _ExportPassphraseSheetState { JsonCodec? codec; } class _ImportOptionsSheetState {}",
      ),
      (
        rule.mainView,
        handler(
          "import 'core/services/json_factory.dart';",
          'final encoder = createCodec().encoder; encoder.convert({});',
        ),
      ),
    ];
    for (var index = 0; index < invalid.length; index++) {
      final (path, text) = invalid[index];
      await fixture(path, text);
      final findings = await rule.check(root);
      require(
        findings.isNotEmpty &&
            findings.every(
              (f) => f.id == rule.id && f.file == path && f.line > 0,
            ),
        'invalid $index',
      );
    }
    final valid = <(String, String)>[
      (
        rule.service,
        "import 'app_preferences.dart'; class ConfigBackupService { void f(AppPreferences owner) { owner.exportBackupSnapshot(); owner.restoreBackupPatch(); } }",
      ),
      (
        rule.mainView,
        handler(
          "class Session { void export() {} void restore() {} }",
          'final session = Session(); session.export(); session.restore();',
        ),
      ),
      (
        rule.mainView,
        handler(
          'class ConfigBackupCodec { static void decode() {} }',
          'ConfigBackupCodec.decode();',
        ),
      ),
      (
        rule.service,
        'class SharedPreferences { String get(String key) => key; } class ConfigBackupService { void f(SharedPreferences ui) { ui.get("label"); } }',
      ),
      (
        rule.mainView,
        handler(
          '',
          'final text = "ConfigBackupCodec.decode()"; /* ConfigBackupService().export() */ print(text);',
        ),
      ),
      (
        rule.sheetView,
        'class _ExportPassphraseSheetState { String render(Map<String,String> labels) => labels["title"] ?? ""; } class _ImportOptionsSheetState {}',
      ),
      (
        rule.mainView,
        handler(
          'class Ui { void remove() {} }',
          'final ui = Ui(); ui.remove();',
        ),
      ),
      (
        rule.mainView,
        handler(
          '',
          'void invoke(void Function() action) { action.call(); } invoke(() {});',
        ),
      ),
      (
        rule.platform,
        "import 'dart:io'; import 'dart:convert'; class ConfigBackupIo { Future<void> f(File file) async { final text = utf8.decode(await file.readAsBytes()); await file.writeAsString(text); } }",
      ),
      (
        rule.platform,
        'class AppPreferences { void restoreBackupPatch() {} } class ConfigBackupIo { void f(AppPreferences ui) { ui.restoreBackupPatch(); } }',
      ),
      (
        rule.mainView,
        handler(
          'String jsonDecode(String label) => label;',
          'jsonDecode("title");',
        ),
      ),
      (
        rule.mainView,
        "import 'core/services/session_barrel.dart' as ui; class HomeScreenState { final ui.Session session = ui.Session(); void _showBackupConfig() { session.export(); final read = session.decode; read(); } void _showRestoreConfig() {} }",
      ),
      (
        rule.mainView,
        "import 'core/services/unrelated_session.dart'; class HomeScreenState { final Session session = Session(); void _showBackupConfig() { final session = Session(); session.export(); } void _showRestoreConfig() {} }",
      ),
      (
        rule.mainView,
        "import 'core/services/unrelated_session.dart'; class HomeScreenState { final Session session = Session(); void _showBackupConfig() { void invoke(Session session) { session.export(); } invoke(Session()); } void _showRestoreConfig() {} }",
      ),
      (
        rule.mainView,
        "import 'core/services/unrelated_session.dart'; class HomeScreenState { final Session session = Session(); void _showBackupConfig() { try { throw Session(); } on Session catch (session) { session.export(); } } void _showRestoreConfig() {} }",
      ),
      (
        rule.sheetView,
        "import 'core/services/unrelated_session.dart'; class _ExportPassphraseSheetState { void clear() {} void f() { clear(); } } class _ImportOptionsSheetState {}"
            .replaceFirst(
              "import 'core/services/unrelated_session.dart'; ",
              '',
            ),
      ),
      (
        rule.sheetView,
        "class JsonCodec {} class _ExportPassphraseSheetState { JsonCodec? codec; } class _ImportOptionsSheetState {}",
      ),
    ];
    for (var index = 0; index < valid.length; index++) {
      await fixture(valid[index].$1, valid[index].$2);
      require((await rule.check(root)).isEmpty, 'valid $index');
    }
    final badInput = <String>[
      'class HomeScreenState {',
      'class HomeScreenState { void _showBackupConfig() {} }',
      handler('', 'dynamic owner; owner.pickBackupFile();'),
      handler(
        "import 'core/services/config_backup.dart' if (dart.library.io) 'core/services/backup_barrel.dart';",
        '',
      ),
      "part 'extra.dart'; $cleanMain",
      "import 'core/services/unrelated_session.dart'; import 'core/services/config_backup_service.dart'; class Base { final ConfigBackupService Session = ConfigBackupService(); } class HomeScreenState extends Base { void _showBackupConfig() { Session.export(); } void _showRestoreConfig() {} }",
    ];
    for (var index = 0; index < badInput.length; index++) {
      await fixture(rule.mainView, badInput[index]);
      var rejected = false;
      try {
        await rule.check(root);
      } on FormatException {
        rejected = true;
      }
      require(rejected, 'input $index');
    }
    final binary = args.isEmpty ? '${root.path}/guard' : args.last;
    if (args.isEmpty) {
      final compile = await runProofProcess(proofDartExecutable, [
        'compile',
        'exe',
        'tools/architecture/rules/backup_owner_boundary.dart',
        '-o',
        binary,
      ]);
      require(compile.exitCode == 0, 'compile');
    }
    for (final example in [
      (invalid.first, 1),
      (valid.first, 0),
      ((rule.mainView, badInput.first), 2),
    ]) {
      await fixture(example.$1.$1, example.$1.$2);
      for (final command in [
        (
          proofDartExecutable,
          [
            'run',
            'tools/architecture/rules/backup_owner_boundary.dart',
            '--root',
            root.path,
          ],
        ),
        (binary, ['--root', root.path]),
      ]) {
        final result = await runProofProcess(command.$1, command.$2);
        require(
          result.exitCode == example.$2,
          'CLI ${example.$2}: ${result.stderr}',
        );
        if (example.$2 == 1) {
          require(
            result.stdout.toString().contains('${rule.service}:1 [${rule.id}]'),
            'CLI diagnostic',
          );
        }
        if (example.$2 == 2) {
          require(
            result.stderr.toString().contains('[${rule.id} INPUT]'),
            'CLI input diagnostic',
          );
        }
      }
    }
    await fixture(rule.mainView, cleanMain);
    for (final command in [
      (
        proofDartExecutable,
        ['run', 'tools/architecture/rules/backup_owner_boundary.dart'],
      ),
      (binary, <String>[]),
    ]) {
      final result = await runProofProcess(command.$1, [
        ...command.$2,
        '--root',
        root.path,
        '--sdk',
        '${root.path}/not-an-sdk',
      ]);
      require(
        result.exitCode == 2 &&
            result.stderr.toString().contains('[${rule.id} INPUT]'),
        'CLI invalid SDK',
      );
    }
    stdout.writeln(
      'PASS ${invalid.length + valid.length + badInput.length} fixtures; source/AOT CLI 1/0/2 and invalid SDK 2',
    );
  } finally {
    await root.delete(recursive: true);
  }
}
