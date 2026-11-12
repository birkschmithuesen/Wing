import 'dart:io';

import '../rules/owned_model_mutation.dart' as rule;
import '../proof_process.dart';

void expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main(List<String> args) =>
    withProofProcesses(() => _proofMain(args));

Future<void> _proofMain(List<String> args) async {
  if (args.isNotEmpty && (args.length != 2 || args.first != '--compiled')) {
    throw const FormatException('Use [--compiled PATH]');
  }
  final root = await Directory.systemTemp.createTemp(
    'wing-owned-model-mutation-',
  );
  Future<void> write(String path, String content) async {
    final file = File('${root.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  try {
    await write(
      '.dart_tool/package_config.json',
      File('.dart_tool/package_config.json').readAsStringSync(),
    );
    await write('lib/core/services/profile_gateway.dart', '''
part 'profile_gateway_part.dart';
''');
    await write('lib/core/services/profile_gateway_part.dart', '''
part of 'profile_gateway.dart';
class ProfileGateway { void post() {} void put() {} void postOwned() {} }
''');
    await write('lib/core/services/administration_repository.dart', '''
class ProfileAdministration { void write() {} }
class AdministrationRepository {
  final void Function() request = () {};
  final void Function() ownedMutation = () {};
}
''');
    await write(
      'lib/core/services/gateway_barrel.dart',
      "export 'profile_gateway.dart';\n",
    );
    final selected = rule.owners.keys.first;
    for (final path in rule.owners.keys.skip(1)) {
      await write(
        path,
        "import 'administration_repository.dart';\n"
        'void f(AdministrationRepository repo) { repo.ownedMutation(); }',
      );
    }
    const gateway = "import 'profile_gateway.dart';\n";
    const owned =
        'void accepted(ProfileGateway gateway) { gateway.postOwned(); }';
    final invalid = [
      '${gateway}void f(ProfileGateway gateway) { gateway.post(); }\n$owned',
      '${gateway}void f(ProfileGateway gateway) { final alias = gateway; alias..put()..post(); }\n$owned',
      '${gateway}void f(ProfileGateway gateway) { final send = gateway.post; send(); }\n$owned',
      "import 'gateway_barrel.dart' as api;\n"
          'typedef Gateway = api.ProfileGateway; void f(Gateway gateway) { gateway.post(); gateway.postOwned(); }',
      "import 'administration_repository.dart';\n$gateway"
          'void f(ProfileAdministration profile, ProfileGateway gateway) { profile.write(); gateway.postOwned(); }',
      "import 'administration_repository.dart';\n$gateway"
          'void f(AdministrationRepository repo, ProfileGateway gateway) { final send = repo.request; send(); gateway.postOwned(); }',
      '${gateway}void f(ProfileGateway gateway) { /* postOwned */ final note = "postOwned"; }',
      '${gateway}extension Wrong on ProfileGateway { void Function() captured() => post; }\n$owned',
      '${gateway}class Child extends ProfileGateway { late final captured = put; }\n$owned',
      "import 'administration_repository.dart';\n$gateway"
          'extension Wrong on AdministrationRepository { void Function() captured() => request; }\n$owned',
      '${gateway}extension Wrong on ProfileGateway { String show() => postOwned.toString(); }',
    ];
    for (var index = 0; index < invalid.length; index++) {
      await write(selected, invalid[index]);
      final findings = await rule.check(root);
      expect(
        findings.isNotEmpty &&
            findings.every(
              (finding) => finding.id == rule.id && finding.line > 0,
            ),
        'invalid $index accepted',
      );
    }
    final valid = [
      '$gateway$owned',
      '${gateway}void f(ProfileGateway gateway) { final alias = gateway; alias..postOwned(); }',
      '${gateway}void f(ProfileGateway gateway) { (gateway.postOwned)(); }',
      '${gateway}void f(ProfileGateway gateway) { (gateway.postOwned).call(); }',
      "import 'gateway_barrel.dart' as api;\n"
          'typedef Gateway = api.ProfileGateway; void f(Gateway gateway) { gateway.postOwned(); }',
      '$gateway$owned\nclass Local { void post() {} void write() {} void request() {} } '
          'void f(Local local) { local..post()..write()..request(); }',
      '$gateway$owned\nvoid f() { final request = () {}; request(); /* gateway.post() */ }',
      '$gateway$owned\nvoid f({void Function()? request}) { request?.call(); }',
    ];
    for (var index = 0; index < valid.length; index++) {
      await write(selected, valid[index]);
      expect((await rule.check(root)).isEmpty, 'valid $index rejected');
    }
    final executable = File(
      'tools/architecture/rules/owned_model_mutation.dart',
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
        'compilation failed: ${compilation.stderr}',
      );
    }
    Future<ProcessResult> cli() => runProofProcess(proofDartExecutable, [
      'run',
      executable,
      '--root',
      root.path,
    ]);
    await write(selected, invalid.first);
    final red = await cli();
    expect(
      red.exitCode == 1 &&
          '${red.stdout}'.contains('[${rule.id}]') &&
          '${red.stdout}'.contains('$selected:2'),
      'actual CLI bad input must exit1 at source line',
    );
    await write(selected, valid.first);
    final green = await cli();
    expect(green.exitCode == 0, 'actual valid CLI failed: ${green.stderr}');
    Future<ProcessResult> aot() =>
        runProofProcess(compiled, ['--root', root.path]);
    await write(selected, invalid.first);
    final compiledRed = await aot();
    expect(
      compiledRed.exitCode == 1 &&
          '${compiledRed.stdout}'.contains('$selected:2'),
      'compiled CLI must reject bound generic dispatch at source line',
    );
    await write(selected, valid.first);
    final compiledGreen = await aot();
    expect(
      compiledGreen.exitCode == 0,
      'compiled SDK discovery failed: ${compiledGreen.stderr}',
    );
    await File('${root.path}/.dart_tool/package_config.json').delete();
    expect(
      (await aot()).exitCode == 2,
      'compiled missing SDK configuration must fail input',
    );
    await write(
      '.dart_tool/package_config.json',
      File('.dart_tool/package_config.json').readAsStringSync(),
    );
    await write(
      selected,
      '${gateway}void f(ProfileGateway gateway) { gateway.\\u0070ost(); }',
    );
    final malformed = await cli();
    expect(
      malformed.exitCode == 2,
      'escaped invalid Dart identifier must fail input',
    );
    await write(
      selected,
      "import 'profile_gateway.dart' if (dart.library.io) 'gateway_barrel.dart';\n$owned",
    );
    final conditional = await cli();
    expect(
      conditional.exitCode == 2,
      'conditional owner must require adaptation',
    );
    await write(selected, "part 'owner_part.dart';");
    expect(
      (await cli()).exitCode == 2,
      'owner part must require scoped guard adaptation',
    );
    stdout.writeln(
      '${rule.id}: 27 fixtures + source/compiled CLI 1/0/2 passed',
    );
  } finally {
    await root.delete(recursive: true);
  }
}
