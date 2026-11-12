import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/dead_code/retired_declarations.dart' as rule;
import '../tools/architecture/model.dart';

List<Finding> operationFindings(
  Map<String, String> sources, {
  Map<String, String> containingLibraries = const {},
  Map<String, Object?>? retirementManifest,
}) {
  final workspace = Directory.systemTemp.createTempSync(
    'wing-operation-retired-',
  );
  try {
    final roles = <String, Object>{};
    for (final entry in sources.entries) {
      final file = File('${workspace.path}/${entry.key}');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
      roles[entry.key] = {
        'role': 'utility',
        'feature': 'operation-fixture',
        'library': containingLibraries[entry.key] ?? entry.key,
      };
    }
    final roleFile = File('${workspace.path}/roles.json');
    roleFile.writeAsStringSync(jsonEncode({'schema': 1, 'files': roles}));
    final manifest = File(
      '${workspace.path}/tools/architecture/dead_code/retired.json',
    );
    manifest.parent.createSync(recursive: true);
    manifest.writeAsStringSync(
      retirementManifest == null
          ? File('tools/architecture/dead_code/retired.json').readAsStringSync()
          : jsonEncode(retirementManifest),
    );
    return rule.check(Snapshot.load(workspace.path, roleFile.path));
  } finally {
    workspace.deleteSync(recursive: true);
  }
}

void main() {
  test(
    'backend animation disposal remains live while controller ownership stays retired',
    () {
      const library = 'lib/core/widgets/backend_version_card.dart';
      expect(
        operationFindings({
          library: 'class _BackendVersionCardState { void dispose() {} }',
        }),
        isEmpty,
      );
      final findings = operationFindings({
        library:
            'class _BackendVersionCardState { bool _ownsController = false; void dispose() {} }',
      });
      expect(findings.map((finding) => finding.subject), [
        '_BackendVersionCardState._ownsController',
      ]);
      expect(findings.single.id, rule.id);
    },
  );

  test('retired enum values use their actual enum and containing library', () {
    const library = 'lib/core/models/app_preferences.dart';
    const part = 'lib/core/models/preferences_enum_part.dart';
    final findings = operationFindings(
      {
        library: "part 'preferences_enum_part.dart';\n",
        part:
            "part of 'app_preferences.dart';\n"
            'enum AppPreferenceIssueKind {\n'
            '  invalidSavedValue,\n'
            '}\n',
      },
      containingLibraries: {part: library},
    );
    expect(findings.map((f) => (f.file, f.line, f.subject)), [
      (part, 2, 'AppPreferenceIssueKind'),
      (part, 3, 'AppPreferenceIssueKind.invalidSavedValue'),
    ]);
    expect(
      operationFindings({
        library: 'enum SupportedIssueKind { invalidSavedValue }',
        'lib/unrelated.dart':
            'enum AppPreferenceIssueKind { invalidSavedValue }',
      }),
      isEmpty,
    );
  });

  test(
    'field retirement keeps supported acknowledgement named constructors',
    () {
      const library = 'lib/core/models/profile_tool_setup.dart';
      expect(
        operationFindings({
          library:
              'class ToolSetupAcknowledgement {\n'
              '  const ToolSetupAcknowledgement.provider();\n'
              '  const ToolSetupAcknowledgement.model();\n'
              '  const ToolSetupAcknowledgement.setup();\n'
              '}\n',
        }),
        isEmpty,
      );
      final findings = operationFindings({
        library:
            'class ToolSetupAcknowledgement {\n'
            '  const ToolSetupAcknowledgement.provider();\n'
            '  const ToolSetupAcknowledgement.model();\n'
            '  const ToolSetupAcknowledgement.setup();\n'
            '  final Object? provider = null;\n'
            '  final Object? model = null;\n'
            '  final Object? setupKey = null;\n'
            '  final Object? capability = null;\n'
            '}\n',
      });
      expect(findings.map((finding) => finding.id), everyElement(rule.id));
      expect(
        findings.map(
          (finding) => (finding.file, finding.line, finding.subject),
        ),
        unorderedEquals([
          (library, 5, 'ToolSetupAcknowledgement.provider'),
          (library, 6, 'ToolSetupAcknowledgement.model'),
          (library, 7, 'ToolSetupAcknowledgement.setupKey'),
          (library, 8, 'ToolSetupAcknowledgement.capability'),
        ]),
      );
    },
  );

  test('explicit any kind retains symbol-wide constructor retirement', () {
    const library = 'lib/core/models/profile_tool_setup.dart';
    final findings = operationFindings(
      {
        library:
            'class ToolSetupAcknowledgement {\n'
            '  const ToolSetupAcknowledgement.provider();\n'
            '}\n',
      },
      retirementManifest: {
        'schema': 2,
        'entries': [
          {
            'library': library,
            'symbol': 'ToolSetupAcknowledgement.provider',
            'kind': 'any',
          },
        ],
      },
    );
    expect(findings, hasLength(1));
    expect(findings.single.subject, 'ToolSetupAcknowledgement.provider');
    expect(findings.single.line, 2);
  });

  const identity = {
    'library': 'lib/core/models/profile_tool_setup.dart',
    'symbol': 'ToolSetupAcknowledgement.provider',
  };
  for (final invalid in [
    {
      'schema': 1,
      'entries': [
        {...identity, 'kind': 'any'},
      ],
    },
    {
      'schema': 2,
      'entries': [identity],
    },
    for (final kind in ['constructor', false, null])
      {
        'schema': 2,
        'entries': [
          {...identity, 'kind': kind},
        ],
      },
  ]) {
    test('retirement manifest rejects unsupported input $invalid', () {
      expect(
        () => operationFindings({
          'lib/core/models/profile_tool_setup.dart': 'class Supported {}',
        }, retirementManifest: invalid),
        throwsFormatException,
      );
    });
  }

  const health = 'lib/core/services/administration_health.dart';
  const page = 'lib/core/screens/administration/admin_operations_page.dart';
  const runtime = 'lib/core/screens/administration/admin_runtime_health.dart';

  test(
    'retired Health polling and public observation mutation fail in actual parts',
    () {
      const part = 'lib/core/services/health_operation_part.dart';
      final findings = operationFindings(
        {
          health: "part 'health_operation_part.dart';\n",
          part:
              "part of 'administration_health.dart';\n"
              'class AdministrationHealth {\n'
              '  void _refreshDiagnostic() {}\n'
              '  void observeDiagnostic() {}\n'
              '}\n',
        },
        containingLibraries: {part: health},
      );
      expect(findings.map((finding) => finding.id), everyElement(rule.id));
      expect(
        findings.map(
          (finding) => (finding.file, finding.line, finding.subject),
        ),
        [
          (part, 3, 'AdministrationHealth._refreshDiagnostic'),
          (part, 4, 'AdministrationHealth.observeDiagnostic'),
        ],
      );
    },
  );

  test('retired view polling and mutable prepared-chat fields fail', () {
    final findings = operationFindings({
      page:
          'class _AdminActionPageState {\n'
          '  Object? _timer;\n'
          '  Object? _preparedChat;\n'
          '}\n',
    });
    expect(findings.map((finding) => finding.id), everyElement(rule.id));
    expect(
      findings.map((finding) => (finding.file, finding.line, finding.subject)),
      [
        (page, 3, '_AdminActionPageState._preparedChat'),
        (page, 2, '_AdminActionPageState._timer'),
      ],
    );
  });

  test('retired UI diagnostic-start helper fails', () {
    final findings = operationFindings({
      runtime: 'void _startDiagnostic() {}\n',
    });
    expect(findings, hasLength(1));
    expect(findings.single.id, rule.id);
    expect(findings.single.file, runtime);
    expect(findings.single.line, 1);
    expect(findings.single.subject, '_startDiagnostic');
  });

  test(
    'typed-owner delegation, moved identity and unrelated homonyms remain valid',
    () {
      final findings = operationFindings({
        'lib/core/models/administration_operation.dart':
            'class AdministrationAction {}\nclass AdminDiagnosticObservation {}\n',
        health:
            'class AdministrationHealth {\n'
            '  Object? diagnosticOperation(String path) => null;\n'
            '  void runAllDiagnostics() {}\n'
            '}\n'
            'class OtherOwner { void observeDiagnostic() {} }\n',
        page:
            'class AdminActionPage { final Object operation; AdminActionPage(this.operation); }\n'
            'class _AdminActionPageState { void _askHermes() {} }\n'
            'class OtherView { Object? _timer; Object? _preparedChat; }\n',
        runtime:
            'void present() { void _startDiagnostic() {} _startDiagnostic(); }\n',
      });
      expect(findings, isEmpty);
    },
  );

  test('retired chat composer fields cannot become a second work writer', () {
    const controller = 'lib/core/services/profile_workspace_controller.dart';
    final findings = operationFindings({
      controller:
          'class ProfileChat {\n'
          "  String draft = '';\n"
          '  final attachments = <Object>[];\n'
          '  final queuedPrompts = <Object>[];\n'
          '  bool queuePaused = false;\n'
          '  Object? _draftWrites;\n'
          '}\n',
    });
    expect(findings.map((finding) => finding.id), everyElement(rule.id));
    expect(
      findings.map((finding) => (finding.file, finding.line, finding.subject)),
      [
        (controller, 6, 'ProfileChat._draftWrites'),
        (controller, 3, 'ProfileChat.attachments'),
        (controller, 2, 'ProfileChat.draft'),
        (controller, 5, 'ProfileChat.queuePaused'),
        (controller, 4, 'ProfileChat.queuedPrompts'),
      ],
    );
  });

  test(
    'retired composer forwarding getters fail in an actual controller part',
    () {
      const controller = 'lib/core/services/profile_workspace_controller.dart';
      const part = 'lib/core/services/chat_composer_part.dart';
      final findings = operationFindings(
        {
          controller: "part 'chat_composer_part.dart';\n",
          part:
              "part of 'profile_workspace_controller.dart';\n"
              'class ProfileChat {\n'
              "  String get composerText => '';\n"
              '  bool get sendingPrompt => false;\n'
              '}\n',
        },
        containingLibraries: {part: controller},
      );
      expect(findings.map((finding) => finding.id), everyElement(rule.id));
      expect(
        findings.map(
          (finding) => (finding.file, finding.line, finding.subject),
        ),
        [
          (part, 3, 'ProfileChat.composerText'),
          (part, 4, 'ProfileChat.sendingPrompt'),
        ],
      );
    },
  );

  test('chat runtime facts and work in its actual owner remain valid', () {
    const controller = 'lib/core/services/profile_workspace_controller.dart';
    final findings = operationFindings({
      controller:
          'class ProfileChat {\n'
          '  final runtime = Object();\n'
          '  final reading = Object();\n'
          '  bool _replacingExpiredRuntime = false;\n'
          '  Object? get composer => null;\n'
          '}\n'
          "class OtherOwner { String draft = ''; bool queuePaused = false; }\n",
      'lib/core/services/composer_session.dart':
          'class ComposerSession {\n'
          "  String draft = '';\n"
          '  final attachments = <Object>[];\n'
          '  final queuedPrompts = <Object>[];\n'
          '  bool queuePaused = false;\n'
          '}\n',
    });
    expect(findings, isEmpty);
  });

  test('retired tool route and UI catalog policy cannot return', () {
    const path = 'lib/core/screens/administration/admin_tool_setup_page.dart';
    final findings = operationFindings({
      path:
          'class AdminToolSetupList {}\n'
          'class _AdminToolModelsPageState {\n'
          '  Object? _pendingModel;\n'
          '  void _readCatalog() {}\n'
          '}\n',
    });
    expect(findings.map((finding) => finding.id), everyElement(rule.id));
    expect(
      findings.map((finding) => (finding.file, finding.line, finding.subject)),
      [
        (path, 1, 'AdminToolSetupList'),
        (path, 3, '_AdminToolModelsPageState._pendingModel'),
        (path, 4, '_AdminToolModelsPageState._readCatalog'),
      ],
    );
  });

  test('retired tool leaf raw messages input cannot return', () {
    const path = 'lib/core/widgets/profile_tool_activity.dart';
    final findings = operationFindings({
      path:
          'class ProfileToolActivity {\n'
          '  final List<Map<String, dynamic>> messages = [];\n'
          '}\n',
    });
    expect(findings, hasLength(1));
    expect(findings.single.id, rule.id);
    expect(
      (findings.single.file, findings.single.line, findings.single.subject),
      (path, 2, 'ProfileToolActivity.messages'),
    );
  });

  test('typed tool and voice views and retained setup wrapper remain valid', () {
    final findings = operationFindings({
      'lib/core/screens/administration/admin_tool_setup_page.dart':
          'class AdminToolSetupPage { final Object createSession; AdminToolSetupPage(this.createSession); }\n'
          'class _AdminToolSetupPageState { void _setup() {} }\n'
          'class AdminToolModelsPage { final Object session; final Object editor; AdminToolModelsPage(this.session, this.editor); }\n',
      'lib/core/screens/administration/admin_voice_page.dart':
          'class AdminVoicePage { final Object createSession; AdminVoicePage(this.createSession); }\n',
      'lib/core/widgets/profile_tool_activity.dart':
          'class ProfileToolActivity { final List<Object> results = []; }\n'
          '',
      'lib/core/models/transcript_timeline.dart':
          'class TranscriptTimelineSection { final List<Object> groups = []; }\n',
    });
    expect(findings, isEmpty);
  });

  test('retired skills wire rows, usage decoder and save baseline fail', () {
    const path = 'lib/core/screens/administration/admin_skills_page.dart';
    final findings = operationFindings({
      path:
          'class AdminSkillDetail {\n'
          '  final Map<String, dynamic> row = {};\n'
          '}\n'
          'class _AdminSkillEditorState {\n'
          "  String _saved = '';\n"
          '}\n'
          'class _AdminSkillLibraryPageState {\n'
          '  int _usage(Map<String, dynamic> row) => 0;\n'
          '}\n',
    });
    expect(findings.map((finding) => finding.id), everyElement(rule.id));
    expect(
      findings.map((finding) => (finding.file, finding.line, finding.subject)),
      [
        (path, 2, 'AdminSkillDetail.row'),
        (path, 5, '_AdminSkillEditorState._saved'),
        (path, 8, '_AdminSkillLibraryPageState._usage'),
      ],
    );
  });

  test('retired Find page bags, view focus and per-chat windows fail', () {
    const findView = 'lib/core/widgets/chat_find_sheet.dart';
    const part = 'lib/core/widgets/find_policy_part.dart';
    const workspace = 'lib/core/screens/profile_workspace_screen.dart';
    const controller = 'lib/core/services/profile_workspace_controller.dart';
    final findings = operationFindings(
      {
        findView: "part 'find_policy_part.dart';\n",
        part:
            "part of 'chat_find_sheet.dart';\n"
            'typedef ChatHistoryPageLoader = Object Function(int offset);\n'
            'class ChatFindResult {}\n'
            'class _ChatFindSheetState {\n'
            '  final _history = <Object>[];\n'
            '  String _rowText(Object row) => row.toString();\n'
            '}\n',
        workspace:
            'class ProfileWorkspaceScreenState {\n'
            '  void _backToLatest() {}\n'
            '  Object? _findOwner;\n'
            '}\n',
        controller:
            'class ProfileChat {\n'
            '  Object? _readingWindow;\n'
            '}\n',
      },
      containingLibraries: {part: findView},
    );
    expect(findings.map((finding) => finding.id), everyElement(rule.id));
    expect(
      findings.map((finding) => (finding.file, finding.line, finding.subject)),
      unorderedEquals([
        (part, 2, 'ChatHistoryPageLoader'),
        (part, 3, 'ChatFindResult'),
        (part, 5, '_ChatFindSheetState._history'),
        (part, 6, '_ChatFindSheetState._rowText'),
        (workspace, 2, 'ProfileWorkspaceScreenState._backToLatest'),
        (workspace, 3, 'ProfileWorkspaceScreenState._findOwner'),
        (controller, 2, 'ProfileChat._readingWindow'),
      ]),
    );
  });

  test('typed skills and Find views and one controller window remain valid', () {
    final findings = operationFindings({
      'lib/core/screens/administration/admin_skills_page.dart':
          'class AdminSkillLibraryPage { final Object createSession; AdminSkillLibraryPage(this.createSession); }\n'
          'class _AdminSkillLibraryPageState { bool _usageOrder = false; }\n'
          'class AdminSkillDetail { final Object session; final Object route; AdminSkillDetail(this.session, this.route); }\n'
          'class _AdminSkillDetailState { void _archive() {} void _uninstall() {} }\n'
          'class _AdminSkillEditorState { void _save() {} void _close() {} }\n'
          'class OtherView { Object? row; String _saved = ""; int _usage() => 0; }\n',
      'lib/core/widgets/chat_find_sheet.dart':
          'class ChatFindSheet { final Object createSession; ChatFindSheet(this.createSession); }\n'
          'class _ChatFindSheetState { void _queryChanged(String query) {} }\n'
          'class OtherView { final _history = <Object>[]; void _rowText() {} }\n',
      'lib/core/screens/profile_workspace_screen.dart':
          'class ProfileWorkspaceScreenState { void _openFind() {} Object? _renderedReadingFocus; }\n'
          'class OtherView { Object? _findOwner; void _backToLatest() {} }\n',
      'lib/core/services/profile_workspace_controller.dart':
          'class ProfileWorkspaceController { Object? _activeReadingWindow; void backToLatest() {} }\n'
          'class ProfileChat { final runtime = Object(); final reading = Object(); }\n',
      'lib/core/services/chat_reading_session.dart':
          'class ChatReadingSession { final _history = <Object>[]; void loadOlder() {} }\n',
      'lib/core/models/chat_reading.dart':
          'class ChatReadingFocus { final int rowId; const ChatReadingFocus(this.rowId); }\n',
      'lib/core/models/unrelated_find.dart': 'class ChatFindResult {}\n',
    });
    expect(findings, isEmpty);
  });

  test(
    'retired declarations guard passes its independent CLI fixtures',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/dead_code/prove_retired.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
