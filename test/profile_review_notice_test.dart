import 'support/canonical_gateway_fixture.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/models/transcript_timeline.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/profile_tool_activity.dart';
import 'package:wing/core/widgets/profile_tool_call.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'package:wing/core/widgets/tool_activity_details.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/models/local_transcript_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/review_notice.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/widgets/profile_review_notice_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/profile_history_fixture.dart';

class _ReviewFixture extends ProfileHistoryFixture {
  final _sequences = <(String, String), int>{};
  final gateways = <String, ProfileGateway>{};
  final runtimeOverrides = <String, String>{};

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    late final ProfileGateway gateway;
    gateway = ProfileGateway(
      scope: scope,
      discover: base.discover,
      connect: () async {
        if (gateway.onEvent != null) gateways[scope.profileName] = gateway;
        await base.connect();
      },
      close: base.close,
      get: base.read,
      rpc: (method, params) async {
        if (method == 'session.resume') {
          final sessionId = params['session_id'] as String;
          final runtime = runtimeOverrides[sessionId] ?? '$sessionId-runtime';
          return {
            ...canonicalSnapshotFields,
            'last_sequence': _sequences[(scope.profileName, runtime)] ?? 0,
            'session_id': runtime,
            'stored_session_id': sessionId,
            'messages': const [],
            'info': {'profile_name': scope.profileName},
          };
        }
        return base.call(method, params);
      },
    );
    return gateway;
  }

  void event(
    String profile,
    String sessionId,
    Map<String, dynamic> data, {
    int? sequence,
  }) {
    final key = (profile, sessionId);
    final nextSequence = sequence ?? (_sequences[key] ?? 0) + 1;
    if (nextSequence > (_sequences[key] ?? 0)) {
      _sequences[key] = nextSequence;
    }
    gateways[profile]!.onEvent!(
      StreamEvent(
        type: 'review.summary',
        data: data,
        sessionId: sessionId,
        envelope: {
          'seq': nextSequence,
          'replay_epoch': canonicalSnapshotFields['replay_epoch'],
          'authority_epoch': canonicalSnapshotFields['authority_epoch'],
          'execution_generation': 0,
        },
      ),
    );
  }
}

void main() {
  Future<void> expandReview(WidgetTester tester) async {
    final title = find.text('Memory and skills review');
    await Scrollable.ensureVisible(tester.element(title), alignment: .5);
    await tester.pumpAndSettle();
    await tester.tap(title);
    await tester.pumpAndSettle();
  }

  setUpAll(() async {
    if (!const bool.fromEnvironment('CAPTURE_MEMORY_ACTIVITY')) return;
    const root = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final font in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            File(
              '$root/${font.value}',
            ).readAsBytes().then((bytes) => bytes.buffer.asByteData()),
          ))
          .load();
    }
  });
  late _ReviewFixture fixture;
  late SharedPreferences preferences;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;

  Future<ProfileWorkspaceController> makeController() async {
    final next = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'review-notices',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: fixture.gateway,
    );
    await next.initialize();
    return next;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    fixture = _ReviewFixture()..messageCount = 0;
    controller = await makeController();
  });

  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  test('a post-reply review joins the tools of that reply', () {
    final source = <Map<String, dynamic>>[
      {
        'id': 1,
        'role': 'user',
        'content': 'Inspect the contract',
        'timestamp': 100,
      },
      {
        'id': 2,
        'role': 'tool',
        'tool_name': 'read_file',
        'content': 'Contract',
      },
      {
        'id': 3,
        'role': 'assistant',
        'content': 'The contract is ready.',
        'timestamp': 120,
      },
      {'id': 4, 'role': 'system', 'content': 'review:Memory updated'},
      {'id': 5, 'role': 'system', 'content': 'review:Skill updated'},
      {'id': 6, 'role': 'user', 'content': 'Next question'},
      {'id': 7, 'role': 'tool', 'content': 'Next result'},
    ];
    final timeline = TranscriptTimeline.project(
      source,
      presentationId: (row) => row['id']!,
    );
    final activities = timeline.sections
        .where((section) => section.isActivity)
        .toList();
    expect(activities, hasLength(2));
    expect(activities.first.toolCount, 1);
    expect(activities.first.reviewCount, 2);
    expect(activities.first.messages.map((row) => row.id), [2, 4, 5]);
    expect(activities.first.replyDuration, const Duration(seconds: 20));
    expect(activities.last.reviewCount, 0);
    expect(timeline.entries.map((row) => row.id), [1, 2, 3, 4, 5, 6, 7]);
  });

  test('a review after a later prompt never claims the earlier reply', () {
    final timeline = TranscriptTimeline.project([
      {'id': 1, 'role': 'tool', 'content': 'Earlier result'},
      {'id': 2, 'role': 'assistant', 'content': 'Earlier answer'},
      {'id': 3, 'role': 'user', 'content': 'Next question'},
      {'id': 4, 'role': 'system', 'content': 'review:Late delivery'},
    ], presentationId: (row) => row['id']!);
    expect(timeline.sections.first.reviewCount, 0);
    expect(timeline.sections.last.reviewCount, 1);
  });

  test(
    'identical summaries from different turns survive refresh and restart',
    () async {
      final scope = controller.current!.scope;
      await controller.openSession(ProfileSessionKey(scope, 'chat-0'));
      final chat = controller.current!.chat!;
      chat.reading.installSavedHistory([
        {'id': 1, 'role': 'user', 'content': 'First question'},
        {'id': 2, 'role': 'assistant', 'content': 'First answer'},
      ]);
      fixture.event('personal', chat.runtime.runtimeId, {
        'text': 'Memory updated',
      });
      chat.reading.installSavedHistory([
        ...chat.reading.messages,
        {'id': 3, 'role': 'user', 'content': 'Second question'},
        {'id': 4, 'role': 'assistant', 'content': 'Second answer'},
      ]);
      fixture.event('personal', chat.runtime.runtimeId, {
        'text': 'Memory updated',
      });
      expect(chat.reviewNotices, hasLength(2));
      final refreshed = retainLocalTranscriptMessages(chat.reading.messages, [
        {'id': 1, 'role': 'user', 'content': 'First question'},
        {'id': 2, 'role': 'assistant', 'content': 'First answer'},
        {'id': 3, 'role': 'user', 'content': 'Second question'},
        {'id': 4, 'role': 'assistant', 'content': 'Second answer'},
      ]);
      expect(refreshed.where(isLocalReviewMessage), hasLength(2));
      chat.reading.installSavedHistory(refreshed);
      controller.dispose();
      await Future<void>.delayed(Duration.zero);
      controller = await makeController();
      await controller.openSession(ProfileSessionKey(scope, 'chat-0'));
      expect(controller.current!.chat!.reviewNotices, hasLength(2));
      expect(
        controller.current!.chat!.reading.messages.where(isLocalReviewMessage),
        hasLength(2),
      );
    },
  );

  test(
    'replaying the same native review sequence does not duplicate it',
    () async {
      final scope = controller.current!.scope;
      await controller.openSession(ProfileSessionKey(scope, 'chat-0'));
      final chat = controller.current!.chat!;
      fixture.event('personal', chat.runtime.runtimeId, {
        'text': 'Memory updated',
      }, sequence: 1);
      fixture.event('personal', chat.runtime.runtimeId, {
        'text': 'Memory updated',
      }, sequence: 1);
      expect(chat.reviewNotices, hasLength(1));
      expect(chat.reading.messages.where(isLocalReviewMessage), hasLength(1));
    },
  );

  testWidgets('review retains supplied previews and exact raw summary', (
    tester,
  ) async {
    const summary =
        '💾 Self-improvement review: Memory ➕ Prefers icon-only actions · '
        'Memory ✏️ Uses Wing on Android… · Skill \'UI review\' patched';
    final scope = controller.current!.scope;
    await controller.openSession(ProfileSessionKey(scope, 'chat-0'));
    final chat = controller.current!.chat!;
    fixture.event('personal', chat.runtime.runtimeId, {'text': summary});
    expect(chat.reading.messages.single['content'], 'review:$summary');
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          createBotsSession: () => BotsSession((_) async => const []),
          controller: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    await expandReview(tester);
    final reported = tester
        .widgetList<ActivityDetailSection>(find.byType(ActivityDetailSection))
        .singleWhere((section) => section.block.label == 'Reported changes');
    expect(reported.block.text, summary.substring(summary.indexOf(':') + 2));
    expect(reported.block.copyText, reported.block.text);
    expect(
      find.textContaining('Individual changes were not included'),
      findsNothing,
    );
    await Scrollable.ensureVisible(
      tester.element(find.text('Raw details')),
      alignment: .5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Raw details'));
    await tester.pumpAndSettle();
    final raw = tester
        .widgetList<ActivityDetailSection>(find.byType(ActivityDetailSection))
        .singleWhere((section) => section.block.label == 'Review summary');
    expect(raw.block.copyText, summary);
    expect(find.byType(BottomSheet), findsNothing);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('memory activity renders ${brightness.name} at $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final boundary = GlobalKey();
        const submitted =
            'The user prefers icon-only actions.\nKeep full names in tooltips.';
        const generic = '💾 Self-improvement review: Memory updated';
        final source = <Map<String, dynamic>>[
          {
            'id': 1,
            'role': 'assistant',
            'content': '',
            'tool_calls': [
              {
                'id': 'retain-example',
                'type': 'function',
                'function': {
                  'name': 'hindsight_retain',
                  'arguments':
                      '{"content":"The user prefers icon-only actions.\\nKeep full names in tooltips."}',
                },
              },
            ],
          },
          {
            'id': 2,
            'role': 'tool',
            'tool_name': 'hindsight_retain',
            'tool_call_id': 'retain-example',
            'content': 'Memory stored successfully.',
          },
          {'id': 3, 'role': 'assistant', 'content': 'Contract inspected.'},
          {'id': 4, 'role': 'system', 'content': 'review:$generic'},
        ];
        Future<void> show(String state, {int? expandedMessageId}) async {
          final timeline = TranscriptTimeline.project(
            source,
            presentationId: (row) => row['id']!,
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: child!,
              ),
              home: RepaintBoundary(
                key: boundary,
                child: Scaffold(
                  body: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final section in timeline.sections)
                        if (section.isActivity)
                          ProfileToolActivitySection(
                            key: ValueKey(state),
                            section: section,
                            expandedMessageId: expandedMessageId,
                          )
                        else
                          ProfileMessage(
                            message:
                                section.groups.single.messages.single.message,
                          ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        await show('generic');
        Future<void> capture(String state) async {
          if (!const bool.fromEnvironment('CAPTURE_MEMORY_ACTIVITY')) return;
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final picture = await render.toImage();
            final bytes = await picture.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/design-previews/memory-activity/site/renders/${brightness.name}-${scale.toInt()}-$state.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            picture.dispose();
          });
        }

        expect(find.text('Memory and skills review'), findsNothing);
        await capture('activity');
        await tester.tap(find.text('Activity · 1 tool'));
        await tester.pumpAndSettle();
        expect(find.byType(ProfileReviewNoticeRow), findsOneWidget);
        expect(find.byType(ProfileToolCall), findsOneWidget);
        expect(find.byIcon(Icons.lightbulb_outline), findsOneWidget);
        expect(
          find.byIcon(ProfileToolCall.iconFor('hindsight_retain')),
          findsOneWidget,
        );
        expect(
          ProfileToolCall.iconFor('hindsight_retain'),
          isNot(Icons.lightbulb_outline),
        );
        await capture('timeline');
        await tester.tap(find.text('Memory and skills review'));
        await tester.pumpAndSettle();
        expect(
          find.text('Individual changes were not included in this summary.'),
          findsOneWidget,
        );
        expect(find.byType(BottomSheet), findsNothing);
        await capture('review');
        await tester.tap(find.text('Memory and skills review'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(ProfileToolCall));
        await tester.pumpAndSettle();
        final payload = tester
            .widgetList<ActivityDetailSection>(
              find.byType(ActivityDetailSection),
            )
            .singleWhere(
              (section) => section.block.label == 'Submitted memory',
            );
        expect(payload.block.copyText, submitted);
        expect(find.text('Retained fact'), findsNothing);
        await capture('retain');
        const preview =
            'Memory ➕ Prefers icon-only action buttons · '
            'User profile ✏️ Uses Wing on Android…';
        final longReview =
            '$preview\n${List.filled(20, "Skill 'UI review' patched with a supplied change preview.").join('\n')}\nLast received change';
        source.last['content'] =
            'review:💾 Self-improvement review: $longReview';
        source[1]['content'] =
            '{"success":false,"error":"Failed to store memory: service unavailable"}';
        await show('detailed', expandedMessageId: 4);
        final changes = tester
            .widgetList<ActivityDetailSection>(
              find.byType(ActivityDetailSection),
            )
            .singleWhere(
              (section) => section.block.label == 'Reported changes',
            );
        expect(changes.block.copyText, longReview);
        expect(
          find.textContaining('Individual changes were not included'),
          findsNothing,
        );
        expect(find.byTooltip('Open Reported changes'), findsOneWidget);
        expect(
          tester
              .widget<ProfileToolCall>(find.byType(ProfileToolCall))
              .call
              .activityDetails
              .response
              .single
              .text,
          contains('service unavailable'),
        );
        await capture('previews-and-failure');
        await tester.tap(find.text('Hindsight retain'));
        await tester.pumpAndSettle();
        await capture('previews');
        await tester.tap(find.byTooltip('Open Reported changes'));
        await tester.pumpAndSettle();
        expect(find.text('Reported changes'), findsWidgets);
        expect(tester.takeException(), isNull);
        Navigator.of(tester.element(find.text('Reported changes').last)).pop();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'review stays before later messages instead of following the chat',
    (tester) async {
      final scope = controller.current!.scope;
      await controller.openSession(ProfileSessionKey(scope, 'chat-0'));
      final chat = controller.current!.chat!;
      fixture.event('personal', chat.runtime.runtimeId, {
        'text': '💾 Self-improvement review: Changes await approval.',
        'timestamp': 401.625,
      });
      expect(chat.reading.messages.single['role'], 'system');
      expect(chat.reading.messages.single['timestamp'], 401.625);
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileWorkspaceScreen(
            createBotsSession: () => BotsSession((_) async => const []),
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Memory and skills review'), findsNothing);
      chat.reading.installSavedHistory([
        ...chat.reading.messages,
        {'id': 1, 'role': 'user', 'content': 'Continue the conversation'},
      ]);
      fixture.event('personal', chat.runtime.runtimeId, const {});
      await tester.pumpAndSettle();

      expect(find.text('Memory and skills review'), findsNothing);
      expect(find.textContaining('Changes await approval.'), findsNothing);
      final activity = find.textContaining(
        RegExp(r'^Activity(?: · \d+ tools?)?$'),
      );
      expect(activity, findsOneWidget);
      expect(
        tester.getTopLeft(activity).dy,
        lessThan(tester.getTopLeft(find.text('Continue the conversation')).dy),
      );
      await tester.tap(activity);
      await tester.pumpAndSettle();
      expect(find.text('Memory and skills review'), findsOneWidget);
      expect(find.text('Changes await approval.'), findsOneWidget);
      expect(find.text('Reported changes'), findsNothing);
      await expandReview(tester);
      final review = find.text('Reported changes');
      expect(review, findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        find.ancestor(of: review, matching: find.byType(Card)),
        findsNothing,
      );
    },
  );

  testWidgets('routes review summaries to the owning chat and opens details', (
    tester,
  ) async {
    final scope = controller.current!.scope;
    await controller.openSession(ProfileSessionKey(scope, 'chat-0'));
    final owner = controller.current!.chat!;
    await controller.openSession(ProfileSessionKey(scope, 'chat-1'));

    fixture.event('personal', owner.runtime.runtimeId, {
      'text': 'Two changes need a closer look.',
    });

    expect(owner.reviewNotices.single.text, 'Two changes need a closer look.');
    expect(controller.current!.chat!.reviewNotices, isEmpty);

    await controller.openSession(owner.key);
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          createBotsSession: () => BotsSession((_) async => const []),
          controller: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ProfileReviewNoticeRow), findsNothing);
    final activity = find.textContaining(
      RegExp(r'^Activity(?: · \d+ tools?)?$'),
    );
    expect(activity, findsOneWidget);
    await tester.tap(activity);
    await tester.pumpAndSettle();
    expect(find.byType(ProfileReviewNoticeRow), findsOneWidget);
    expect(find.text('Memory and skills review'), findsOneWidget);
    expect(find.text('Reported changes'), findsNothing);
    await expandReview(tester);
    expect(find.text('Reported changes'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
  });

  for (final entry in <String, Map<String, dynamic>>{
    'missing': {},
    'blank': {'text': '   '},
    'number': {'text': 7},
    'list': {
      'text': ['review'],
    },
    'object': {
      'text': {'summary': 'review'},
    },
  }.entries) {
    test('ignores ${entry.key} review summary', () async {
      final scope = controller.current!.scope;
      await controller.openSession(ProfileSessionKey(scope, 'chat-0'));
      final chat = controller.current!.chat!;
      fixture.event('personal', chat.runtime.runtimeId, entry.value);
      expect(chat.reviewNotices, isEmpty);
      expect(chat.reading.messages.where(isLocalReviewMessage), isEmpty);
    });
  }

  test('keeps only the newest bounded review set', () async {
    final scope = controller.current!.scope;
    await controller.openSession(ProfileSessionKey(scope, 'chat-0'));
    final chat = controller.current!.chat!;
    fixture.event('personal', chat.runtime.runtimeId, {'text': 'Review 0'});
    for (var i = 0; i <= 20; i++) {
      fixture.event('personal', chat.runtime.runtimeId, {'text': 'Review $i'});
    }

    expect(chat.reviewNotices, hasLength(20));
    expect(chat.reviewNotices.first.text, 'Review 1');
    expect(chat.reviewNotices.last.text, 'Review 20');
    expect(chat.reading.messages.where(isLocalReviewMessage), hasLength(20));
  });

  test(
    'refresh retains review position and excludes it from history offsets',
    () async {
      fixture.messageCount = 220;
      final scope = controller.current!.scope;
      await controller.openSession(ProfileSessionKey(scope, 'chat-0'));
      final chat = controller.current!.chat!;
      final offset = chat.reading.nextHistoryOffset;
      fixture.event('personal', chat.runtime.runtimeId, {
        'text': 'First review',
      });
      fixture.event('personal', chat.runtime.runtimeId, {
        'text': 'Second review',
      });
      fixture.messageCount = 222;
      await controller.refreshHistory(chat);

      final first = chat.reading.messages.indexWhere(
        (row) => reviewMessageText(row) == 'First review',
      );
      expect(chat.reading.messages[first - 1]['id'], 220);
      expect(
        reviewMessageText(chat.reading.messages[first + 1]),
        'Second review',
      );
      expect(chat.reading.messages[first + 2]['id'], 221);
      expect(chat.reading.nextHistoryOffset, offset! + 2);
      while (chat.reading.nextHistoryOffset != null) {
        final before = chat.reading.nextHistoryOffset;
        await controller.loadOlderMessages(chat);
        expect(chat.reading.historyError, isNull);
        expect(chat.reading.nextHistoryOffset, isNot(before));
      }
      expect(
        chat.reading.messages.where((row) => row['id'] is int),
        hasLength(222),
      );
      expect(chat.reading.messages.where(isLocalReviewMessage), hasLength(2));
      expect(chat.reading.messages.first['id'], 1);
    },
  );

  test(
    'reviews join tool activity without swallowing ordinary system text',
    () {
      final sections = TranscriptTimeline.project([
        {'id': 1, 'role': 'tool', 'content': 'Skill updated'},
        {'id': 2, 'role': 'system', 'content': 'review:Skill update details'},
        {'id': 3, 'role': 'tool', 'content': 'Verified'},
        {'id': 4, 'role': 'system', 'content': 'Ordinary notice'},
        {'id': 5, 'role': 'assistant', 'content': 'review:Quoted example'},
      ], presentationId: (_) => Object()).sections;
      expect(sections, hasLength(3));
      expect(sections.first.isActivity, isTrue);
      expect(sections.first.messages, hasLength(3));
      expect(sections[1].isActivity, isFalse);
      expect(sections[2].isActivity, isFalse);
    },
  );

  test(
    'a stored review replaces its local copy without reordering reviews',
    () {
      final before = {'id': 1, 'role': 'user', 'content': 'Earlier prompt'};
      final first = {
        'id': 'local-first',
        'role': 'system',
        'content': 'review:First',
        '_review_notice': 'first',
      };
      final second = {
        'id': 'local-second',
        'role': 'system',
        'content': 'review:Second',
        '_review_notice': 'second',
      };
      final merged = retainLocalTranscriptMessages(
        [before, first, second],
        [
          before,
          {'id': 2, 'role': 'system', 'content': 'review:First'},
          {'id': 3, 'role': 'assistant', 'content': 'Later answer'},
        ],
      );
      expect(merged.map((row) => row['id']), [1, 2, 'local-second', 3]);
    },
  );

  testWidgets('long review details scroll on a narrow screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final text =
        '${List.filled(30, 'Skill update details.').join('\n')}\nLast detail';
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: ListView(children: [ProfileReviewNoticeRow(text: text)]),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.lightbulb_outline));
    await tester.pumpAndSettle();
    expect(find.text('Reported changes'), findsOneWidget);
    final section = tester.widget<ActivityDetailSection>(
      find.byType(ActivityDetailSection),
    );
    expect(section.block.copyText, text);
    final scrolls = tester.stateList<ScrollableState>(find.byType(Scrollable));
    final scroll = scrolls.firstWhere(
      (state) => state.position.maxScrollExtent > 0,
    );
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    expect(scroll.position.pixels, greaterThan(0));
    expect(scroll.position.pixels, scroll.position.maxScrollExtent);
    expect(tester.takeException(), isNull);
  });

  test(
    'received reviews survive runtime replacement and controller restart',
    () async {
      final scope = controller.current!.scope;
      await controller.openSession(ProfileSessionKey(scope, 'chat-0'));
      final chat = controller.current!.chat!;
      fixture.event('personal', chat.runtime.runtimeId, {
        'text': 'Transient review',
      });

      await controller.reconnect(scope);
      expect(chat.reviewNotices.single.text, 'Transient review');
      expect(chat.reading.messages.where(isLocalReviewMessage), hasLength(1));

      fixture.runtimeOverrides['chat-0'] = 'chat-0-replaced-runtime';
      await controller.reconnect(scope);
      expect(chat.reviewNotices.single.text, 'Transient review');
      expect(chat.reading.messages.where(isLocalReviewMessage), hasLength(1));

      fixture.event('personal', chat.runtime.runtimeId, {
        'text': 'Another review',
      });
      controller.dispose();
      await Future<void>.delayed(Duration.zero);
      controller = await makeController();
      await controller.openSession(ProfileSessionKey(scope, 'chat-0'));
      expect(
        controller.current!.chat!.reviewNotices.map((notice) => notice.text),
        ['Transient review', 'Another review'],
      );
      expect(
        controller.current!.chat!.reading.messages.where(isLocalReviewMessage),
        hasLength(2),
      );
    },
  );
}
