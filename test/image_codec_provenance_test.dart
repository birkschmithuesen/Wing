import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/rules/image_codec_provenance.dart' as provenance;
import 'architecture_contract_test.dart' show FixtureWorkspace;

FixtureWorkspace fixture({
  String imageVersion = '4.12.0',
  String imagePin = '4.12.0',
  String? override,
  String? imageHash,
}) {
  final workspace = FixtureWorkspace({
    'files': {
      'lib/value.dart': {'role': 'domain', 'source': 'class Value {}'},
    },
  });
  File('${workspace.directory.path}/pubspec.yaml').writeAsStringSync(
    'name: fixture\ndependencies:\n  image: "$imagePin"\n${override == null ? '' : 'dependency_overrides:\n  image: "$override"\n'}',
  );
  File('${workspace.directory.path}/pubspec.lock').writeAsStringSync(
    'packages:\n${provenance.auditedCodecs.entries.map((entry) => '  ${entry.key}:\n    version: "${entry.key == 'image' ? imageVersion : entry.value.$1}"\n    source: hosted\n    description:\n      name: ${entry.key}\n      url: "https://pub.dev"\n      sha256: ${entry.key == 'image' ? imageHash ?? entry.value.$2 : entry.value.$2}\n').join()}',
  );
  return workspace;
}

void main() {
  for (final entry in <String, FixtureWorkspace Function()>{
    'audited hosted artifacts': () => fixture(),
    'codec upgrade': () => fixture(imageVersion: '4.12.1'),
    'floating constraint': () => fixture(imagePin: '^4.12.0'),
    'same version different bytes': () => fixture(imageHash: 'different'),
    'package override': () => fixture(override: '4.12.0'),
    'unrelated optional override': () {
      final workspace = fixture();
      File(
        '${workspace.directory.path}/pubspec_overrides.yaml',
      ).writeAsStringSync('dependency_overrides:\n  unrelated: "1.0.0"\n');
      return workspace;
    },
    'optional override file': () {
      final workspace = fixture();
      File(
        '${workspace.directory.path}/pubspec_overrides.yaml',
      ).writeAsStringSync(
        'dependency_overrides:\n  archive:\n    path: ./alternate\n',
      );
      return workspace;
    },
  }.entries) {
    test(entry.key, () {
      final workspace = entry.value();
      addTearDown(workspace.dispose);
      expect(
        provenance.check(workspace.snapshot).isEmpty,
        {
          'audited hosted artifacts',
          'unrelated optional override',
        }.contains(entry.key),
      );
    });
  }
  test(
    'actual standalone CLI bad 1, valid 0, invalid input 2',
    () async {
      final bad = fixture(imageVersion: '5.0.0'), valid = fixture();
      addTearDown(bad.dispose);
      addTearDown(valid.dispose);
      Future<ProcessResult> invoke(FixtureWorkspace workspace) =>
          Process.run('dart', [
            'run',
            'tools/architecture/rules/image_codec_provenance.dart',
            '--root',
            workspace.directory.path,
            '--roles',
            workspace.rolesPath,
            '--strict',
          ]);
      final rejected = await invoke(bad);
      expect(
        rejected.exitCode,
        1,
        reason: '${rejected.stdout}${rejected.stderr}',
      );
      expect(
        rejected.stdout,
        contains('pubspec.lock:3 [ARCH_IMAGE_CODEC_PROVENANCE]'),
      );
      final accepted = await invoke(valid);
      expect(
        accepted.exitCode,
        0,
        reason: '${accepted.stdout}${accepted.stderr}',
      );
      final overrides = File('${valid.directory.path}/pubspec_overrides.yaml');
      overrides.writeAsStringSync(
        'dependency_overrides:\n  image:\n    path: ./alternate\n',
      );
      final overridden = await invoke(valid);
      expect(
        overridden.exitCode,
        1,
        reason: '${overridden.stdout}${overridden.stderr}',
      );
      expect(
        overridden.stdout,
        contains('pubspec_overrides.yaml:3 [ARCH_IMAGE_CODEC_PROVENANCE]'),
      );
      overrides.deleteSync();
      File(
        '${valid.directory.path}/pubspec.lock',
      ).writeAsStringSync('packages: [bad yaml');
      final invalid = await invoke(valid);
      expect(invalid.exitCode, 2, reason: '${invalid.stdout}${invalid.stderr}');
      expect(invalid.stderr, contains('[ARCH_INPUT]'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
