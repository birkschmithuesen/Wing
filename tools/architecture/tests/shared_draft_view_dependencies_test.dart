import 'dart:convert';
import 'dart:io';

import '../model.dart';
import '../rules/shared_draft_view_dependencies.dart' as rule;
import '../proof_process.dart';

const _view = rule.view;
const _adapter = 'lib/core/services/profile_workspace_controller.dart';
const _otherAdapter = 'lib/core/services/android_share_intent_service.dart';
const _attachments = 'lib/core/services/attachment_draft_service.dart';
const _savedWork = 'lib/core/models/composer_work.dart';
const _owner = 'lib/core/services/shared_draft_session.dart';
const _model = 'lib/core/models/shared_draft.dart';
const _part = 'lib/core/screens/share_part.dart';
const _page = 'class _SharedDraftReview {}';

class _Case {
  const _Case(this.name, this.files, this.exit, {this.libraries = const {}});
  final String name;
  final Map<String, String> files;
  final int exit;
  final int line = 1;
  final Map<String, String> libraries;
}

// The accepted capabilities fixtures retain the shared namespace robustness.
// These cases protect this actual completed boundary without another matrix.
const _cases = [
  _Case('original-direct', {
    _view: "import '../services/profile_workspace_controller.dart';\n$_page",
    _adapter: 'class ProfileWorkspaceController {}',
  }, 1),
  _Case('native-adapter-barrel', {
    _view: "import '../../barrel.dart'; $_page",
    'lib/barrel.dart':
        "export 'core/services/android_share_intent_service.dart';",
    _otherAdapter: 'class AndroidSharePayload {}',
  }, 1),
  _Case(
    'actual-part',
    {
      _view:
          "import '../services/attachment_draft_service.dart';\npart 'share_part.dart';",
      _part: "part of 'shared_draft_review.dart'; $_page",
      _attachments: 'class AttachmentDraftService {}',
    },
    1,
    libraries: {_part: _view},
  ),
  _Case('raw-saved-work', {
    _view: "import '../models/composer_work.dart'; $_page",
    _savedWork: 'class ComposerSavedWork {}',
  }, 1),
  _Case('typed-owner', {
    _view:
        "import '../services/shared_draft_session.dart'; import '../models/shared_draft.dart'; $_page",
    _owner:
        "import 'profile_workspace_controller.dart'; import 'attachment_draft_service.dart'; import 'android_share_intent_service.dart'; import '../models/composer_work.dart'; class SharedDraftSession {}",
    _model:
        'class SharedDraftFile { const SharedDraftFile(this.name); final String name; }',
    _adapter: 'class ProfileWorkspaceController {}',
    _otherAdapter: 'class AndroidSharePayload {}',
    _attachments: 'class AttachmentDraftService {}',
    _savedWork: 'class ComposerSavedWork {}',
  }, 0),
  _Case('homonymous-model-and-members', {
    _view:
        "import '../models/android_share_intent_service.dart'; $_page class OtherView { void acknowledgeShare() {} void stageSharedDraft() {} }",
    'lib/core/models/android_share_intent_service.dart':
        'class AndroidSharePayload {}',
  }, 0),
  _Case('missing-part', {_view: "part 'share_part.dart'; $_page"}, 2),
];

Future<void> main() => withProofProcesses(() => _proofMain());

Future<void> _proofMain() async {
  const representatives = {
    'original-direct': 1,
    'typed-owner': 0,
    'missing-part': 2,
  };
  final exercised = <String, int>{};
  for (final fixture in _cases) {
    final directory = Directory.systemTemp.createTempSync(
      'wing-shared-draft-deps-',
    );
    try {
      final roles = <String, Object>{};
      for (final entry in fixture.files.entries) {
        final file = File('${directory.path}/${entry.key}');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(entry.value);
        roles[entry.key] = {
          'role': entry.key == _view ? 'view' : 'utility',
          'feature': 'shared-draft',
          'library': fixture.libraries[entry.key] ?? entry.key,
        };
      }
      final rolePath = '${directory.path}/roles.json';
      File(
        rolePath,
      ).writeAsStringSync(jsonEncode({'schema': 1, 'files': roles}));
      var actual = 0;
      var findings = <Finding>[];
      try {
        final snapshot = Snapshot.load(directory.path, rolePath);
        findings = rule.check(snapshot);
        actual = findings.isEmpty ? 0 : 1;
      } on FormatException {
        actual = 2;
      }
      if (actual != fixture.exit ||
          (actual == 1 &&
              (findings.length != 1 ||
                  findings.single.id != rule.id ||
                  findings.single.file != _view ||
                  findings.single.line != fixture.line))) {
        throw StateError(
          '${fixture.name}: expected ${fixture.exit}, got $actual / $findings',
        );
      }
      if (representatives.containsKey(fixture.name)) {
        if (exercised.containsKey(fixture.name) ||
            representatives[fixture.name] != fixture.exit) {
          throw StateError('Duplicate or altered CLI representative');
        }
        exercised[fixture.name] = fixture.exit;
        final result = await runProofProcess(proofDartExecutable, [
          'run',
          'tools/architecture/rules/shared_draft_view_dependencies.dart',
          '--root',
          directory.path,
          '--roles',
          rolePath,
          '--json',
        ]);
        if (result.exitCode != fixture.exit) {
          throw StateError(
            '${fixture.name}: CLI ${result.exitCode}: ${result.stdout} ${result.stderr}',
          );
        }
        if (fixture.exit == 2) {
          if (!(result.stderr as String).contains('[ARCH_INPUT]')) {
            throw StateError('Missing CLI input diagnostic');
          }
        } else {
          final json = jsonDecode(result.stdout as String) as Map;
          final diagnostics = json['problems'] as List;
          if (fixture.exit == 0
              ? diagnostics.isNotEmpty
              : diagnostics.length != 1 ||
                    (diagnostics.single as Map)['id'] != rule.id ||
                    (diagnostics.single as Map)['file'] != _view ||
                    (diagnostics.single as Map)['line'] != fixture.line) {
            throw StateError('CLI diagnostic identity/location mismatch');
          }
        }
      }
    } finally {
      directory.deleteSync(recursive: true);
    }
  }
  if (exercised.length != representatives.length ||
      representatives.entries.any(
        (entry) => exercised[entry.key] != entry.value,
      )) {
    throw StateError('CLI exits 1/0/2 were not all proved');
  }
  stdout.writeln(
    '${rule.id}: ${_cases.length} detector fixtures; three CLI representatives passed',
  );
}
