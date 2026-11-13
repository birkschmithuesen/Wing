import 'dart:convert';
import 'dart:io';

import '../rules/browser_row_work.dart' as rule;
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
  final root = await Directory.systemTemp.createTemp('wing-browser-row-');
  final sdk = File(proofDartExecutable).parent.parent.path;
  final viewFile = File('${root.path}/${rule.browserLibrary}');
  Future<void> put(String path, String value) async {
    final file = File('${root.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsString(value);
  }

  const controller = '''
class ProfileWorkspaceController {
  Object? browserResource(String value) => null;
  Object? browserChat(String value) => null;
}
''';
  const header = "import 'profile_workspace_controller.dart';\n";
  String view(
    String body, {
    String extra = '',
    String imports = header,
    String extendsType = '',
  }) =>
      '''
${imports}class ChatBrowserData $extendsType {
  final controller = ProfileWorkspaceController();
  $extra
  void _refreshRow(String key) { $body }
}
''';
  final invalid = <String>[
    view('controller.browserResource(key);'),
    view('final alias = controller; alias.browserResource(key);'),
    view('void nested() { controller.browserResource(key); } nested();'),
    view('final read = controller.browserResource; read(key);'),
    view('controller..browserResource(key);'),
    view(
      'ProfileWorkspaceController? value = controller; value?.browserResource(key);',
    ),
    view(
      'final read = (controller.browserResource); final second = read; second(key);',
    ),
    view(
      'lookup(key);',
      extra: 'late final lookup = controller.browserResource;',
    ),
    view(
      'second(key);',
      extra:
          'late final lookup = controller.browserResource; late final second = lookup;',
    ),
    view(
      'lookup(key);',
      extra:
          'Object? Function(String) get lookup => controller.browserResource;',
    ),
    view(
      'browserResource(key);',
      extendsType: 'extends ProfileWorkspaceController',
    ),
    view(
      'final value = Child(); value.browserResource(key);',
      extra: '',
      imports: '${header}class Child extends ProfileWorkspaceController {}\n',
    ),
    view(
      'final read = p.ProfileWorkspaceController().browserResource; read(key);',
      imports: '${header}import "barrel.dart" as p;\n',
    ),
    view(
      'final read = Selected().browserResource; read(key);',
      imports: '${header}import "alias.dart";\n',
    ),
    view('externalLookup(key);', imports: '${header}import "lookup.dart";\n'),
    view(
      'delegated.second(key);',
      imports: '${header}import "lookup.dart" as delegated;\n',
    ),
    view(
      'controller.browserResource(key); // after comment\n',
      imports:
          '${header}import "barrel.dart" show ProfileWorkspaceController;\n',
    ),
    view('topLookup(key);', imports: '${header}import "getter_lookup.dart";\n'),
    view(
      'lookup(key);',
      extra:
          'late final lookup = (String value) => controller.browserResource(value);',
    ),
    view(
      'final dynamic first = controller.browserResource; final second = first; second(key);',
    ),
    view(
      'late Object? Function(String) lookup; lookup = controller.browserResource; lookup(key);',
    ),
    view(
      'pkg.ProfileWorkspaceController().browserResource(key);',
      imports:
          '${header}import "package:wing/core/services/profile_workspace_controller.dart" as pkg;\n',
    ),
    view(
      'lookup(key);',
      extra:
          'Object? Function(String) get lookup { return controller.browserResource; }',
    ),
    view('topBlock(key);', imports: '${header}import "getter_lookup.dart";\n'),
  ];
  final valid = <String>[
    view('controller.browserChat(key);'),
    view(
      'final value = Local(); value.browserResource(key);',
      imports: '${header}class Local { void browserResource(String key) {} }\n',
    ),
    view(
      'final read = Local().browserResource; read(key);',
      imports: '${header}class Local { void browserResource(String key) {} }\n',
    ),
    view('void browserResource(String key) {} browserResource(key);'),
    view(
      "final text = 'controller.browserResource(key)'; // browserResource\n text.length;",
    ),
    view(
      'controller.browserChat(key);',
      extra: 'void fullIndex() { controller.browserResource("other"); }',
    ),
    view(
      'final lookup = controller.browserChat; lookup(key);',
      extra: 'late final lookup = controller.browserResource;',
    ),
    view(
      'other.ProfileWorkspaceController().browserResource(key);',
      imports: '${header}import "unrelated.dart" as other;\n',
    ),
    view(
      'lookup(key);',
      extra: 'late final lookup = Local().browserResource;',
      imports: '${header}class Local { void browserResource(String key) {} }\n',
    ),
    view('browserResource: for (var i=0;i<1;i++) { break browserResource; }'),
    view(
      'controller.browserChat(key);',
      imports:
          '${header}import "barrel.dart" hide ProfileWorkspaceController;\n',
    ),
    // No candidate: ordinary semantic diagnostics belong to the mandatory SDK
    // gate, not to a selective member-identity detector.
    view('ordinaryMissingName;'),
    view(
      'cached.toString();',
      extra: 'late final cached = controller.browserResource("once");',
    ),
    view(
      'topLookup(key);',
      imports: '${header}import "getter_unrelated.dart";\n',
    ),
    view(
      'controller.browserChat(key);',
      extra: 'void resourceWork() { controller.browserResource("other"); }',
    ),
    view(
      'lookup(key);',
      extra:
          'Object? Function(String) get lookup { return Local().browserResource; }',
      imports:
          '${header}class Local { Object? browserResource(String key) => null; }\n',
    ),
    view(
      'topBlock(key);',
      imports: '${header}import "getter_unrelated.dart";\n',
    ),
  ];
  final input = <String>[
    view('controller.browserResource(key'),
    view('missing.browserResource(key);'),
    view('dynamic value = controller; value.browserResource(key);'),
    view(
      'controller.browserChat(key);',
      imports: '${header}import "missing.dart";\n',
    ),
    view(
      'controller.browserChat(key);',
      imports: '${header}export "missing.dart";\n',
    ),
    view(
      'controller.browserChat(key);',
      imports:
          '${header}import "barrel.dart" if (dart.library.io) "alias.dart";\n',
    ),
    view(
      'controller.browserChat(key);',
      imports: '${header}import "wrong_part.dart";\n',
    ),
    'part of "profile_workspace_controller.dart"; class ChatBrowserData { void _refreshRow(String key) {} }',
    '${header}class ChatBrowserData {}',
    view(
      'controller.browserResource(key); final UnknownThing unused = throw 0;',
    ),
    view(
      'controller.browserChat(key);',
      imports: '${header}import "dart:nonexistent_review";\n',
    ),
  ];
  try {
    final configFile = File('.dart_tool/package_config.json');
    final config =
        jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
    for (final package in (config['packages'] as List).cast<Map>()) {
      package['rootUri'] = package['name'] == 'wing'
          ? root.uri.toString()
          : configFile.absolute.uri
                .resolve(package['rootUri'] as String)
                .toString();
    }
    await put('.dart_tool/package_config.json', jsonEncode(config));
    await put(rule.controllerLibrary, controller);
    await put(
      'lib/core/services/barrel.dart',
      "export 'profile_workspace_controller.dart';\n",
    );
    await put(
      'lib/core/services/alias.dart',
      "import 'profile_workspace_controller.dart'; typedef Selected = ProfileWorkspaceController;\n",
    );
    await put('lib/core/services/lookup.dart', '''
import 'profile_workspace_controller.dart';
final externalLookup = ProfileWorkspaceController().browserResource;
final second = externalLookup;
''');
    await put(
      'lib/core/services/unrelated.dart',
      'class ProfileWorkspaceController { void browserResource(String key) {} }',
    );
    await put(
      'lib/core/services/wrong_part.dart',
      "part of 'profile_workspace_controller.dart';\n",
    );
    await put('lib/core/services/getter_lookup.dart', '''
import 'profile_workspace_controller.dart';
final capturedController = ProfileWorkspaceController();
Object? Function(String) get topLookup => capturedController.browserResource;
Object? Function(String) get topBlock { return capturedController.browserResource; }
''');
    await put('lib/core/services/getter_unrelated.dart', '''
class Local { Object? browserResource(String key) => null; }
Object? Function(String) get topLookup => Local().browserResource;
Object? Function(String) get topBlock { return Local().browserResource; }
''');
    for (var i = 0; i < invalid.length; i++) {
      await put(rule.browserLibrary, invalid[i]);
      final findings = await (() async {
        try {
          return await rule.check(root);
        } catch (error) {
          throw StateError('invalid fixture $i: $error');
        }
      })();
      require(findings.isNotEmpty, 'invalid $i accepted');
      require(
        findings.every(
          (value) =>
              value.id == rule.id &&
              value.line > 0 &&
              value.file == rule.browserLibrary,
        ),
        'invalid $i diagnostic identity/location',
      );
    }
    for (var i = 0; i < valid.length; i++) {
      await viewFile.writeAsString(valid[i]);
      require((await rule.check(root)).isEmpty, 'valid $i rejected');
    }
    for (var i = 0; i < input.length; i++) {
      await viewFile.writeAsString(input[i]);
      var rejected = false;
      try {
        await rule.check(root);
      } on FormatException {
        rejected = true;
      }
      require(rejected, 'input $i accepted');
    }
    // Actual containing-library provenance, even for a part outside lib/.
    final partUri = File('${root.path}/row_part.dart').uri;
    final ownerUri = viewFile.uri;
    await viewFile.writeAsString('${header}part "$partUri";\n');
    await put(
      'row_part.dart',
      "part of '$ownerUri';\n${view('controller.browserResource(key);', imports: '')}",
    );
    require(
      (await rule.check(
        root,
      )).any((finding) => finding.file == 'row_part.dart'),
      'outside-lib containing part must fail',
    );
    await put(
      'row_part.dart',
      "part of '$ownerUri';\n${view('controller.browserChat(key);', imports: '')}",
    );
    require(
      (await rule.check(root)).isEmpty,
      'valid outside-lib containing part',
    );
    await put(
      'row_part.dart',
      "part of '${File('${root.path}/${rule.controllerLibrary}').uri}';\n${view('controller.browserChat(key);', imports: '')}",
    );
    var badPart = false;
    try {
      await rule.check(root);
    } on FormatException {
      badPart = true;
    }
    require(badPart, 'wrong containing part accepted');

    // Physical parent existence is insufficient for a package-origin namespace.
    // The original51 binary accepted this input although the SDK rejected it.
    final configured = File('${root.path}/.dart_tool/package_config.json');
    final beforeConfig = configured.readAsStringSync();
    final packageData = jsonDecode(beforeConfig) as Map;
    (packageData['packages'] as List).add({
      'name': 'bridge',
      'rootUri': '${root.uri}bridge/',
      'packageUri': 'lib/',
      'languageVersion': '3.12',
    });
    await configured.writeAsString(jsonEncode(packageData));
    await put('bridge/lib/entry.dart', "part '../piece.dart';\n");
    await put('bridge/piece.dart', "part of 'lib/entry.dart';\n");
    await viewFile.writeAsString(
      view(
        'controller.browserChat(key);',
        imports: '${header}import "package:bridge/entry.dart";\n',
      ),
    );
    var missingOrigin = false;
    try {
      await rule.check(root);
    } on FormatException {
      missingOrigin = true;
    }
    require(missingOrigin, 'missing actual package-relative part accepted');
    await put('bridge/lib/entry.dart', "part 'piece.dart';\n");
    await put('bridge/lib/piece.dart', "part of 'entry.dart';\n");
    require(
      (await rule.check(root)).isEmpty,
      'valid actual package-relative part',
    );
    await configured.writeAsString(beforeConfig);

    final binary = args.isEmpty ? '${root.path}/browser-row-guard' : args[1];
    if (args.isEmpty) {
      final result = await runProofProcess(proofDartExecutable, [
        'compile',
        'exe',
        'tools/architecture/rules/browser_row_work.dart',
        '-o',
        binary,
      ]);
      require(
        result.exitCode == 0,
        'compile: ${result.stdout} ${result.stderr}',
      );
    }
    for (final example in [
      (invalid.first, 1),
      (valid.first, 0),
      (input[2], 2),
      (invalid[7], 1),
      (invalid[9], 1),
      (invalid[17], 1),
      (invalid.last, 1),
      (valid[12], 0),
      (valid[7], 0),
      (input[3], 2),
    ]) {
      await viewFile.writeAsString(example.$1);
      for (final command in [
        (
          proofDartExecutable,
          [
            'run',
            'tools/architecture/rules/browser_row_work.dart',
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
          require('${result.stdout}'.contains(rule.id), 'CLI finding ID');
        }
        if (example.$2 == 2) {
          require(
            '${result.stderr}'.contains('${rule.id} INPUT'),
            'CLI INPUT ID',
          );
        }
      }
    }
    await viewFile.writeAsString(valid.first);
    for (final command in [
      (
        proofDartExecutable,
        [
          'run',
          'tools/architecture/rules/browser_row_work.dart',
          '--root',
          root.path,
          '--sdk',
          '${root.path}/missing',
        ],
      ),
      (binary, ['--root', root.path, '--sdk', '${root.path}/missing']),
    ]) {
      require(
        (await runProofProcess(command.$1, command.$2)).exitCode == 2,
        'invalid SDK must fail before clean filter',
      );
    }
    await File(
      '${root.path}/.dart_tool/package_config.json',
    ).rename('${root.path}/.dart_tool/package_config.held');
    require(
      (await rule.check(root, sdkPath: sdk)).isEmpty,
      'explicit SDK/no config',
    );
    final explicit = await runProofProcess(binary, [
      '--root',
      root.path,
      '--sdk',
      sdk,
    ]);
    require(
      explicit.exitCode == 0,
      'compiled explicit SDK/no config ${explicit.stderr}',
    );
    stdout.writeln(
      'PASS ${invalid.length + valid.length + input.length + 5} browser-row fixtures; source/fresh-AOT CLI1/0/2, invalid SDK2 and explicit SDK/no config0',
    );
  } finally {
    await root.delete(recursive: true);
  }
}
