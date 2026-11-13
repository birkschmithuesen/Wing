import 'package:wing/core/screens/profile_transcript.dart';
import 'package:wing/core/models/transcript_presentation.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/transcript_reading.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/gateway_activity.dart';
import 'package:wing/core/models/hermes_question.dart';
import 'package:wing/core/presentation/tool_call_presentation.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/models/transcript_timeline.dart';
import 'package:wing/core/widgets/profile_tool_activity.dart';
import 'package:wing/core/widgets/source_code_text.dart';
import 'package:wing/core/widgets/profile_tool_call.dart';
import 'package:wing/core/widgets/tool_activity_details.dart';

const _capture = bool.fromEnvironment('CAPTURE_QUESTION_FAMILY');
final _frame = GlobalKey();

Future<void> capture(WidgetTester tester, String name) async {
  if (!_capture) return;
  await tester.runAsync(() async {
    final boundary =
        _frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('build/design-previews/question-timeline')
      ..createSync(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

HermesQuestion question(HermesQuestionStatus status) => HermesQuestion(
  id: 'approval/request',
  requestId: 'request',
  kind: HermesQuestionKind.approval,
  status: status,
  timestamp: DateTime(2026, 10, 15, 13, 27),
  description: 'Inspect the selected source',
  command: 'cat selected.txt',
  sender: 'Research bot',
);

Future<void> showQuestion(
  WidgetTester tester,
  HermesQuestion value, {
  Brightness brightness = Brightness.light,
  double scale = 1,
}) async {
  await showActivity(
    tester,
    value.status == HermesQuestionStatus.pending
        ? ProfileToolCall(call: ToolCallPresentation.question(value))
        : ProfileToolActivitySection(
            section: TranscriptTimeline.project(
              const [],
              presentationId: (row) => row['id']!,
              requestActivities: [PositionedHermesQuestion(value)],
            ).sections.single,
          ),
    brightness: brightness,
    scale: scale,
  );
  if (value.status != HermesQuestionStatus.pending &&
      find.text('Asked a question').evaluate().isEmpty) {
    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
  }
}

Future<void> showActivity(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
  double scale = 1,
}) => tester.pumpWidget(
  MaterialApp(
    theme: wingTheme(brightness),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: RepaintBoundary(
      key: _frame,
      child: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  ),
);

void main() {
  setUpAll(() async {
    if (!_capture) return;
    for (final (family, path) in [
      (WingTypography.sans, 'build/studio-roboto.ttf'),
      ('MaterialIcons', 'build/studio-icons.otf'),
      ('monospace', 'build/studio-mono.ttf'),
    ]) {
      await (FontLoader(
        family,
      )..addFont(File(path).readAsBytes().then(ByteData.sublistView))).load();
    }
  });
  testWidgets('a request-only transcript uses the normal collapsed Activity', (
    tester,
  ) async {
    final reader = TranscriptReading.passive(
      scope: WorkspaceScope(
        connectionId: 'fixture',
        connectionIdentity: 'fixture',
        profileName: 'default',
      ),
    );
    final timeline = TranscriptTimeline.project(
      const [],
      presentationId: (row) => row['id']!,
      requestActivities: [
        PositionedHermesQuestion(question(HermesQuestionStatus.expired)),
      ],
    );
    await showActivity(
      tester,
      SizedBox(
        height: 600,
        child: ProfileTranscript(
          presentation: TranscriptPresentation.capture(
            identity: 'request-only',
            reader: reader,
            timeline: timeline,
            needsInput: false,
            turnAdmissionBlocked: false,
          ),
          onRefreshHistory: () async {},
          messageBuilder: (_) => throw StateError(
            'Request escaped Activity into message rendering',
          ),
          emptyContent: const Text('No conversation content'),
          tail: const [],
        ),
      ),
    );
    expect(find.text('No conversation content'), findsNothing);
    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('Asked a question'), findsNothing);
    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(ProfileActivityTimeline),
        matching: find.byType(ProfileToolCall),
      ),
      findsOneWidget,
    );
    expect(find.byType(SourceCodeText), findsNothing);
  });

  testWidgets('request history uses the default Wing Activity presentation', (
    tester,
  ) async {
    await showQuestion(tester, question(HermesQuestionStatus.expired));
    expect(find.byType(ProfileToolCall), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byType(ProfileToolCall),
        matching: find.byType(ProfileActivityTimeline),
      ),
      findsOneWidget,
    );
    expect(find.text('Asked a question'), findsOneWidget);
    expect(find.byType(ActivityDetailsCard), findsNothing);
    await tester.tap(find.text('Asked a question'));
    await tester.pumpAndSettle();
    expect(find.byType(ActivityDetailsCard), findsOneWidget);
    expect(find.text('Expired'), findsWidgets);
    expect(find.text('Raw details'), findsOneWidget);
  });
  for (final (status, label) in [
    (HermesQuestionStatus.pending, 'Pending'),
    (HermesQuestionStatus.approved, 'Approved'),
    (HermesQuestionStatus.rejected, 'Rejected'),
    (HermesQuestionStatus.answered, 'Answered'),
    (HermesQuestionStatus.expired, 'Expired'),
    (HermesQuestionStatus.cancelled, 'Cancelled'),
    (HermesQuestionStatus.closed, 'Closed'),
  ]) {
    testWidgets('history reports the $label outcome without live controls', (
      tester,
    ) async {
      await showQuestion(tester, question(status));
      expect(
        find.text(
          status == HermesQuestionStatus.pending
              ? 'Asking a question'
              : 'Asked a question',
        ),
        findsOneWidget,
      );
      expect(find.textContaining(label), findsWidgets);
      // A recorded pending request is historical information; response
      // authority belongs to the live request owner and its separate controls.
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Allow once'), findsNothing);
      expect(find.byTooltip('Confirm answer and continue'), findsNothing);
    });
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'question details disclose and retire at ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = const Size(360, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final value = question(HermesQuestionStatus.expired);
          await showQuestion(
            tester,
            value,
            brightness: brightness,
            scale: scale,
          );
          expect(find.byType(SourceCodeText), findsNothing);
          expect(find.text(value.description), findsNothing);
          await capture(tester, 'approval-collapsed-${brightness.name}-$scale');

          await tester.tap(find.text('Asked a question'));
          await tester.pumpAndSettle();
          expect(find.text(value.description), findsOneWidget);
          expect(find.byType(SourceCodeText), findsOneWidget);
          expect(
            tester.widget<SourceCodeText>(find.byType(SourceCodeText)).text,
            'cat selected.txt',
          );
          await capture(tester, 'approval-expanded-${brightness.name}-$scale');
          await tester.ensureVisible(find.byTooltip('Copy Command'));
          await tester.pumpAndSettle();
          expect(find.byTooltip('Copy Command').hitTestable(), findsOneWidget);

          await tester.ensureVisible(find.text('Asked a question'));
          await tester.tap(find.text('Asked a question'));
          await tester.pumpAndSettle();
          expect(find.byType(SourceCodeText), findsNothing);
          expect(find.text(value.description), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
      testWidgets(
        'native questions keep choices and answers at ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          const prompt = 'How should I handle live validation?';
          const answer = 'Resume the group and verify processing.';
          const choices = ['Keep the group stopped.', answer];
          final call = ToolCallPresentation.live(
            GatewayToolActivity.fromGatewayEvent('tool.complete', {
              'tool_id': 'native-clarify',
              'name': 'clarify',
              'args': {
                'questions': [
                  {'question': prompt, 'choices': choices},
                ],
              },
              'result': {
                'responses': [
                  {
                    'question': prompt,
                    'choices_offered': choices,
                    'status': 'answered',
                    'user_response': answer,
                  },
                ],
              },
            })!,
          );
          await showActivity(
            tester,
            ProfileToolCall(call: call),
            brightness: brightness,
            scale: scale,
          );
          await tester.tap(find.text('Asked a question'));
          await tester.pumpAndSettle();
          Finder section(String label) => find.ancestor(
            of: find.text(label),
            matching: find.byType(ActivityDetailSection),
          );
          expect(
            find.descendant(
              of: section('Question'),
              matching: find.text(prompt, findRichText: true),
            ),
            findsOneWidget,
          );
          for (final choice in choices) {
            expect(
              find.descendant(
                of: section('Choices'),
                matching: find.textContaining(choice, findRichText: true),
              ),
              findsOneWidget,
            );
          }
          expect(
            find.descendant(
              of: section('Answer'),
              matching: find.text(answer, findRichText: true),
            ),
            findsOneWidget,
          );
          expect(find.text('Answered'), findsOneWidget);
          expect(find.text('Completed'), findsOneWidget);
          expect(find.byType(ProfileActivitySection), findsNothing);
          await capture(tester, 'native-expanded-${brightness.name}-$scale');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('settled observation updates the expanded history in place', (
    tester,
  ) async {
    final pending = question(HermesQuestionStatus.closed);
    await showQuestion(tester, pending);
    await tester.tap(find.text('Asked a question'));
    await tester.pumpAndSettle();

    await showQuestion(
      tester,
      pending.withStatus(HermesQuestionStatus.approved),
    );
    await tester.pumpAndSettle();
    expect(find.text('Asked a question'), findsOneWidget);
    expect(find.text('Approved'), findsOneWidget);
    expect(find.text(pending.description), findsOneWidget);
    expect(find.byType(SourceCodeText), findsOneWidget);
  });

  testWidgets('secure input history contains only the authored prompt', (
    tester,
  ) async {
    final value = HermesQuestion(
      id: 'secure/request',
      requestId: 'request',
      kind: HermesQuestionKind.secureInput,
      status: HermesQuestionStatus.answered,
      timestamp: DateTime(2026, 10, 15),
      description: 'Which source should I inspect?',
    );
    await showQuestion(tester, value);
    await tester.tap(find.text('Asked a question'));
    await tester.pumpAndSettle();
    expect(find.text(value.description), findsOneWidget);
    expect(find.byType(SourceCodeText), findsNothing);
    expect(find.byTooltip('Copy Command'), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });
}
