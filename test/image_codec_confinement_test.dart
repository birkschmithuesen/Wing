import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/rules/image_codec_confinement.dart' as codec;
import 'architecture_contract_test.dart' show FixtureWorkspace;

void main() {
  final cases =
      (jsonDecode(
                File(
                  'tools/architecture/fixtures/image_codec.fixture.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>)['cases']
          as List;
  for (final fixture in cases.cast<Map<String, dynamic>>()) {
    test(fixture['name'] as String, () {
      final workspace = FixtureWorkspace(fixture);
      addTearDown(workspace.dispose);
      final findings = codec.check(workspace.snapshot);
      expect(findings, hasLength(fixture['count'] as int));
      for (final finding in findings) {
        expect(finding.id, codec.id);
        expect(finding.line, greaterThan(0));
      }
    });
  }
  test(
    'standalone CLI rejects bad source, accepts worker, and rejects invalid input',
    () async {
      final bad = FixtureWorkspace({
        'files': {
          'lib/service.dart': {
            'role': 'data',
            'source': "import 'package:image/image.dart' as codec;",
          },
        },
      });
      final valid = FixtureWorkspace({
        'files': {
          codec.workerLibrary: {
            'role': 'data',
            'source': "import 'package:image/image.dart' as codec;",
          },
        },
      });
      addTearDown(bad.dispose);
      addTearDown(valid.dispose);
      Future<ProcessResult> invoke(
        FixtureWorkspace workspace, {
        String? roles,
      }) => Process.run('dart', [
        'run',
        'tools/architecture/rules/image_codec_confinement.dart',
        '--root',
        workspace.directory.path,
        '--roles',
        roles ?? workspace.rolesPath,
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
        contains('lib/service.dart:1 [ARCH_IMAGE_CODEC_CONFINEMENT]'),
      );
      final accepted = await invoke(valid);
      expect(
        accepted.exitCode,
        0,
        reason: '${accepted.stdout}${accepted.stderr}',
      );
      final invalid = await invoke(
        valid,
        roles: '${valid.directory.path}/missing.json',
      );
      expect(invalid.exitCode, 2, reason: '${invalid.stdout}${invalid.stderr}');
      expect(invalid.stderr, contains('[ARCH_INPUT]'));
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
