import 'dart:convert';
import 'dart:io';

import '../model.dart';
import '../rules/reading_view_inputs.dart' as rule;
import '../proof_process.dart';

const message = 'lib/core/widgets/profile_message.dart';
const tools = 'lib/core/widgets/profile_tool_activity.dart';
const transcript = 'lib/core/screens/profile_transcript.dart';
const runtime = 'lib/core/services/profile_workspace_controller.dart';
const runtimePart = 'lib/core/services/profile_workspace_notifications.dart';
const canonicalImport = "import '../models/transcript_message.dart';\n";
const timelineImport =
    "import '../models/transcript_timeline.dart'; import '../models/transcript_presentation.dart';\n";

class _Case {
  const _Case(
    this.name,
    this.messageType,
    this.resultsType,
    this.exit, {
    this.imports = canonicalImport,
    this.extra = '',
    this.timelineType = 'TranscriptPresentation',
    this.presentationTimelineType = 'TranscriptTimeline',
    this.sectionType = 'TranscriptTimelineSection',
    this.timelineImports = timelineImport,
    this.timelineExtra = '',
    this.sectionExtra = '',
    this.missing = false,
    this.part = false,
    this.unrelatedRuntime = false,
    this.subjects = const [
      'ProfileMessage.message',
      'ProfileToolActivity.results',
    ],
  });
  final String name, messageType, resultsType, imports, extra;
  final String presentationTimelineType;
  final String timelineType,
      sectionType,
      timelineImports,
      timelineExtra,
      sectionExtra;
  final int exit;
  final bool missing, part, unrelatedRuntime;
  final List<String> subjects;
}

const cases = [
  _Case(
    'raw-timeline-in-presentation',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    1,
    presentationTimelineType: 'List<Map<String, dynamic>>',
    subjects: ['TranscriptPresentation.timeline'],
  ),
  _Case(
    'original-wire-inputs',
    'Map<String, dynamic>',
    'List<Map<String, dynamic>>',
    1,
  ),
  _Case(
    'nullable-widening',
    'TranscriptMessage?',
    'List<TranscriptToolResult?>',
    1,
  ),
  _Case('object-widening', 'Object?', 'List<Object?>', 1),
  _Case('dynamic-widening', 'dynamic', 'dynamic', 1),
  _Case(
    'same-spelling-local-fake',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    1,
    extra: 'class TranscriptMessage {}',
    subjects: ['ProfileMessage.message'],
  ),
  _Case(
    'typed-inputs-and-unrelated-homonyms',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    0,
    extra: 'class OtherView { final Map<String, dynamic> message = {}; }',
    timelineExtra:
        'class OtherTimelineView { final Map<String, dynamic> timeline = {}; }',
    sectionExtra:
        'class OtherSectionView { final Map<String, dynamic> section = {}; }',
  ),
  _Case(
    'prefixed-normalized-canonical-import',
    'facts.TranscriptMessage',
    'core.List<facts.TranscriptToolResult>',
    0,
    imports:
        "import 'package:wing/core/widgets/../models/transcript_message.dart' as facts show TranscriptMessage, TranscriptToolResult;\nimport 'dart:core' as core;\n",
    timelineImports:
        "import 'package:wing/core/screens/../models/transcript_timeline.dart' as timeline show TranscriptTimeline, TranscriptTimelineSection; import 'package:wing/core/models/transcript_presentation.dart' as presentation;\n",
    timelineType: 'presentation.TranscriptPresentation',
    sectionType: 'timeline.TranscriptTimelineSection',
    unrelatedRuntime: true,
  ),
  _Case(
    'missing-completed-input',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    2,
    missing: true,
  ),
  _Case(
    'unsupported-part-scope',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    2,
    part: true,
  ),
  _Case(
    'raw-timeline-and-section-inputs',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    1,
    timelineType: 'List<Map<String, dynamic>>',
    sectionType: 'List<List<Map<String, dynamic>>>',
    subjects: [
      'ProfileTranscript.presentation',
      'ProfileToolActivitySection.section',
    ],
  ),
  _Case(
    'nullable-timeline-and-dynamic-section',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    1,
    timelineType: 'TranscriptPresentation?',
    sectionType: 'dynamic',
    subjects: [
      'ProfileTranscript.presentation',
      'ProfileToolActivitySection.section',
    ],
  ),
  _Case(
    'same-spelling-timeline-and-section-fakes',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    1,
    timelineExtra: 'class TranscriptPresentation {}',
    sectionExtra: 'class TranscriptTimelineSection {}',
    subjects: [
      'ProfileTranscript.presentation',
      'ProfileToolActivitySection.section',
    ],
  ),
  _Case(
    'copied-pending-input-union',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    1,
    timelineExtra:
        'class _ProfileTranscriptState { bool needed() => widget.chat.runtime.approval != null || widget.chat.runtime.pendingQuestion != null || widget.chat.runtime.secureInput != null; }',
    subjects: ['ProfileTranscript.needsInput'],
  ),
  _Case(
    'captured-reordered-parenthesized-union',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    1,
    timelineExtra:
        'class _ProfileTranscriptState { bool needed() { final owned = widget.chat; return (null != (owned.runtime.secureInput)) || ((owned.runtime.approval) != null || owned.runtime.pendingQuestion != null); } }',
    subjects: ['ProfileTranscript.needsInput'],
  ),
  _Case(
    'canonical-input-and-request-specific-rendering',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    0,
    timelineExtra:
        'class _ProfileTranscriptState { bool needed() { final chat = widget.chat; return chat.runtime.needsInput; } bool approvalVisible() => widget.chat.runtime.approval != null; }',
  ),
  _Case(
    'unrelated-class-same-union',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    0,
    timelineExtra:
        'class OtherState { bool needed() => widget.chat.runtime.approval != null || widget.chat.runtime.pendingQuestion != null || widget.chat.runtime.secureInput != null; }',
  ),
  _Case(
    'unrelated-local-same-members',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    0,
    timelineExtra:
        'class _ProfileTranscriptState { bool needed() { final chat = other; return chat.runtime.approval != null || chat.runtime.pendingQuestion != null || chat.runtime.secureInput != null; } }',
  ),
  _Case(
    'nearer-shadowed-capture',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    0,
    timelineExtra:
        'class _ProfileTranscriptState { bool needed() { final chat = widget.chat; { final chat = other; return chat.runtime.approval != null || chat.runtime.pendingQuestion != null || chat.runtime.secureInput != null; } } }',
  ),
  _Case(
    'different-receivers-do-not-form-one-fact',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    0,
    timelineExtra:
        'class _ProfileTranscriptState { bool needed() => widget.chat.runtime.approval != null || other.runtime.pendingQuestion != null || widget.chat.runtime.secureInput != null; }',
  ),
  _Case(
    'parameter-homonym-is-not-captured',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    0,
    timelineExtra:
        'class _ProfileTranscriptState { bool needed(chat) => chat.runtime.approval != null || chat.runtime.pendingQuestion != null || chat.runtime.secureInput != null; }',
  ),
  _Case(
    'closure-parameter-homonym-is-not-captured',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    0,
    timelineExtra:
        'class _ProfileTranscriptState { void needed() { final chat = widget.chat; consume((chat) => chat.runtime.approval != null || chat.runtime.pendingQuestion != null || chat.runtime.secureInput != null); } }',
  ),

  _Case(
    'literal-widget-parameter-is-unrelated',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    0,
    timelineExtra:
        'class _ProfileTranscriptState { bool needed(widget) => widget.chat.runtime.approval != null || widget.chat.runtime.pendingQuestion != null || widget.chat.runtime.secureInput != null; }',
  ),
  _Case(
    'loop-declaration-shadow',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    0,
    timelineExtra:
        'class _ProfileTranscriptState { bool needed() { final chat = widget.chat; for (final chat in others) { return chat.runtime.approval != null || chat.runtime.pendingQuestion != null || chat.runtime.secureInput != null; } return false; } }',
  ),

  _Case(
    'loop-pattern-shadow',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    0,
    timelineExtra:
        'class _ProfileTranscriptState { bool needed() { final chat = widget.chat; for (final (chat,) in others) { return chat.runtime.approval != null || chat.runtime.pendingQuestion != null || chat.runtime.secureInput != null; } return false; } }',
  ),

  _Case(
    'catch-shadow',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    0,
    timelineExtra:
        'class _ProfileTranscriptState { bool needed() { final chat = widget.chat; try { action(); } catch (chat) { return chat.runtime.approval != null || chat.runtime.pendingQuestion != null || chat.runtime.secureInput != null; } return false; } }',
  ),

  _Case(
    'pattern-local-shadow',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    0,
    timelineExtra:
        'class _ProfileTranscriptState { bool needed() { final chat = widget.chat; { final (chat,) = other; return chat.runtime.approval != null || chat.runtime.pendingQuestion != null || chat.runtime.secureInput != null; } return false; } }',
  ),

  _Case(
    'if-case-shadow',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    0,
    timelineExtra:
        'class _ProfileTranscriptState { bool needed() { final chat = widget.chat; if (other case final chat) { return chat.runtime.approval != null || chat.runtime.pendingQuestion != null || chat.runtime.secureInput != null; } return false; } }',
  ),

  _Case(
    'switch-case-shadow',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    0,
    timelineExtra:
        'class _ProfileTranscriptState { bool needed() { final chat = widget.chat; switch (other) { case final chat: return chat.runtime.approval != null || chat.runtime.pendingQuestion != null || chat.runtime.secureInput != null; } return false; } }',
  ),

  _Case(
    'widget-loop',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    0,
    timelineExtra:
        'class _ProfileTranscriptState { bool needed() { for (final widget in others) { return widget.chat.runtime.approval != null || widget.chat.runtime.pendingQuestion != null || widget.chat.runtime.secureInput != null; } return false; } }',
  ),

  _Case(
    'widget-catch',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    0,
    timelineExtra:
        'class _ProfileTranscriptState { bool needed() { try { action(); } catch (widget) { return widget.chat.runtime.approval != null || widget.chat.runtime.pendingQuestion != null || widget.chat.runtime.secureInput != null; } return false; } }',
  ),

  _Case(
    'widget-pattern',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    0,
    timelineExtra:
        'class _ProfileTranscriptState { bool needed() { final (widget,) = other; return widget.chat.runtime.approval != null || widget.chat.runtime.pendingQuestion != null || widget.chat.runtime.secureInput != null; return false; } }',
  ),
  _Case(
    'switch-expression-pattern-shadow',
    'TranscriptMessage',
    'List<TranscriptToolResult>',
    0,
    timelineExtra:
        'class _ProfileTranscriptState { bool needed() { final chat = widget.chat; return switch (other) { final chat => chat.runtime.approval != null || chat.runtime.pendingQuestion != null || chat.runtime.secureInput != null }; } }',
  ),
];

Future<void> main() => withProofProcesses(() => _proofMain());

Future<void> _proofMain() async {
  final cliExits = <int>{};
  for (final fixture in cases) {
    final root = Directory.systemTemp.createTempSync('wing-reading-input-');
    try {
      final files = {
        rule.model:
            'final class TranscriptMessage {} final class TranscriptToolResult {}',
        rule.timelineModel:
            'final class TranscriptTimeline {} final class TranscriptTimelineSection {}',
        rule.presentationModel:
            "import 'transcript_timeline.dart';\nfinal class TranscriptPresentation { final ${fixture.presentationTimelineType} timeline; }",
        message:
            '${fixture.imports}${fixture.part ? "part 'reading_part.dart';\n" : ''}'
            'class ProfileMessage { ${fixture.missing ? '' : 'final ${fixture.messageType} message;'} }\n'
            '${fixture.extra}\n',
        tools:
            '${fixture.imports}${fixture.timelineImports}class ProfileToolActivity { final ${fixture.resultsType} results; }\n'
            'class ProfileToolActivitySection { final ${fixture.sectionType} section; }\n'
            '${fixture.sectionExtra}\n',
        transcript:
            '${fixture.unrelatedRuntime ? "import '../services/profile_workspace_controller.dart';\n" : ''}'
            '${fixture.timelineImports}class ProfileTranscript { final ${fixture.timelineType} presentation; }\n'
            '${fixture.timelineExtra}\n',
        if (fixture.unrelatedRuntime) ...{
          runtime:
              "part 'profile_workspace_notifications.dart'; class ProfileChat {}",
          runtimePart:
              "part of 'profile_workspace_controller.dart'; class RuntimeNotification {}",
        },
        if (fixture.part)
          'lib/core/widgets/reading_part.dart':
              "part of 'profile_message.dart'; class Other {}",
      };
      final roles = <String, Object>{};
      for (final entry in files.entries) {
        final file = File('${root.path}/${entry.key}');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(entry.value);
        roles[entry.key] = {
          'role': rule.models.containsKey(entry.key) ? 'domain' : 'view',
          'feature': 'reading-fixture',
          'library': entry.key.endsWith('reading_part.dart')
              ? message
              : entry.key == runtimePart
              ? runtime
              : entry.key,
        };
      }
      final rolesPath = '${root.path}/roles.json';
      File(
        rolesPath,
      ).writeAsStringSync(jsonEncode({'schema': 1, 'files': roles}));
      var exit = 0;
      var findings = <Finding>[];
      try {
        findings = rule.check(Snapshot.load(root.path, rolesPath));
        exit = findings.isEmpty ? 0 : 1;
      } on FormatException {
        exit = 2;
      }
      if (exit != fixture.exit) {
        throw StateError(
          '${fixture.name}: expected ${fixture.exit}, got $exit',
        );
      }
      if (exit == 1) {
        final tuples = [
          for (final finding in findings)
            (finding.id, finding.file, finding.line, finding.subject),
        ];
        final expected = [
          for (final subject in fixture.subjects)
            (
              rule.id,
              subject == 'TranscriptPresentation.timeline'
                  ? rule.presentationModel
                  : subject.startsWith('ProfileMessage.')
                  ? message
                  : subject.startsWith('ProfileTranscript.')
                  ? transcript
                  : tools,
              subject == 'ProfileTranscript.needsInput'
                  ? 3
                  : subject == 'TranscriptPresentation.timeline' ||
                        subject.startsWith('ProfileMessage.') ||
                        subject.startsWith('ProfileTranscript.')
                  ? 2
                  : subject.startsWith('ProfileToolActivitySection.')
                  ? 4
                  : 3,
              subject,
            ),
        ];
        if (jsonEncode(tuples.map((t) => [t.$1, t.$2, t.$3, t.$4]).toList()) !=
            jsonEncode(
              expected.map((t) => [t.$1, t.$2, t.$3, t.$4]).toList(),
            )) {
          throw StateError(
            '${fixture.name}: wrong diagnostic identity/location: $findings',
          );
        }
      }
      if ({
        'original-wire-inputs',
        'copied-pending-input-union',
        'typed-inputs-and-unrelated-homonyms',
        'missing-completed-input',
      }.contains(fixture.name)) {
        if (!cliExits.add(exit) &&
            fixture.name != 'copied-pending-input-union') {
          throw StateError('Duplicate CLI representative');
        }
        final result = await runProofProcess(proofDartExecutable, [
          'run',
          'tools/architecture/rules/reading_view_inputs.dart',
          '--root',
          root.path,
          '--roles',
          rolesPath,
          '--json',
        ]);
        if (result.exitCode != exit) {
          throw StateError(
            '${fixture.name}: CLI ${result.exitCode}: ${result.stdout} ${result.stderr}',
          );
        }
        if (exit == 2) {
          if (!(result.stderr as String).contains('[ARCH_INPUT]')) {
            throw StateError('Missing CLI input diagnostic');
          }
        } else {
          final output = jsonDecode(result.stdout as String) as Map;
          final problems = output['problems'] as List;
          if (problems.length != findings.length) {
            throw StateError('CLI diagnostic count mismatch');
          }
          for (var i = 0; i < findings.length; i++) {
            final actual = problems[i] as Map;
            final finding = findings[i];
            if (actual['id'] != finding.id ||
                actual['file'] != finding.file ||
                actual['line'] != finding.line ||
                actual['subject'] != finding.subject) {
              throw StateError('CLI diagnostic identity/location mismatch');
            }
          }
        }
      }
    } finally {
      root.deleteSync(recursive: true);
    }
  }
  if (cliExits.length != 3) throw StateError('CLI exits 1/0/2 not exercised');
  stdout.writeln(
    '${rule.id}: ${cases.length} detector fixtures; four CLI representatives passed',
  );
}
