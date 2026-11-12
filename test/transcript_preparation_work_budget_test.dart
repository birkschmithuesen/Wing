import 'package:wing/core/models/transcript_presentation.dart';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/models/transcript_timeline.dart';
import 'package:wing/core/screens/profile_transcript.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/widgets/profile_tool_activity.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/composer_fixture.dart';
import 'support/profile_history_fixture.dart';

// Reading the location is necessary for preparing an attachment, but never for
// indexing the containing message's identity, ordering or activity boundary.
class _ImageLocation extends MapBase<String, dynamic> {
  int reads = 0;
  @override
  dynamic operator [](Object? key) {
    if (key != 'url') return null;
    reads++;
    return 'data:image/png;base64,${'A' * 65536}';
  }

  @override
  Iterable<String> get keys => const ['url'];
  @override
  void operator []=(String key, dynamic value) =>
      throw UnsupportedError('read only');
  @override
  void clear() => throw UnsupportedError('read only');
  @override
  dynamic remove(Object? key) => throw UnsupportedError('read only');
}

class _Arguments extends MapBase<String, dynamic> {
  int reads = 0;
  @override
  dynamic operator [](Object? key) {
    reads++;
    return key == 'query' ? 'historical search' : null;
  }

  @override
  Iterable<String> get keys => const ['query'];
  @override
  void operator []=(String key, dynamic value) =>
      throw UnsupportedError('read only');
  @override
  void clear() => throw UnsupportedError('read only');
  @override
  dynamic remove(Object? key) => throw UnsupportedError('read only');
}

class _ReasoningDetails extends ListBase<Object?> {
  int tailReads = 0;
  @override
  int get length => 2;
  @override
  Object? operator [](int index) {
    if (index == 1) tailReads++;
    return {'type': 'reasoning.text', 'text': 'Part $index'};
  }

  @override
  set length(int value) => throw UnsupportedError('read only');
  @override
  void operator []=(int index, Object? value) =>
      throw UnsupportedError('read only');
}

void main() {
  List<Map<String, dynamic>> imageRows(List<_ImageLocation> images) => [
    for (var i = 0; i < images.length; i++)
      {
        'id': i + 1,
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'Caption ${i + 1}'},
          {'type': 'image_url', 'image_url': images[i]},
        ],
      },
  ];
  TranscriptTimeline project(List<Map<String, dynamic>> rows) =>
      TranscriptTimeline.project(rows, presentationId: (row) => row['id']!);

  test('reasoning presence does not prepare the remaining body', () {
    final details = _ReasoningDetails();
    final timeline = project([
      {
        'id': 1,
        'role': 'assistant',
        'content': '',
        'reasoning_details': details,
      },
    ]);
    expect(timeline.entries.single.hasReasoning, isTrue);
    expect(details.tailReads, 0);
    expect(timeline.entries.single.reasoning, 'Part 0\n\nPart 1');
    expect(details.tailReads, 1);
  });

  test('timeline identity and grouping do not read attachment bodies', () {
    final images = List.generate(100, (_) => _ImageLocation());
    final timeline = project(imageRows(images));
    expect(timeline.sections, hasLength(100));
    expect(timeline.sections.last.presentationIds, [100]);
    expect(timeline.nearby(50)!.sections, hasLength(9));
    expect(images.fold(0, (sum, image) => sum + image.reads), 0);
    final message = timeline.entries.last.message;
    expect(message.text, 'Caption 100');
    expect(message.attachments, hasLength(1));
    expect(images.last.reads, 1);
    expect(images.take(99).every((image) => image.reads == 0), isTrue);
  });

  test(
    'a new reading revision prepares its own body for the same identity',
    () {
      final first = project([
        {'id': 1, 'role': 'assistant', 'content': 'Before refresh'},
      ]);
      expect(first.entries.single.message.text, 'Before refresh');
      final refreshed = project([
        {'id': 1, 'role': 'assistant', 'content': 'After refresh'},
      ]);
      expect(refreshed.entries.single.presentationId, 1);
      expect(refreshed.entries.single.message.text, 'After refresh');
      expect(first.entries.single.message.text, 'Before refresh');
    },
  );

  testWidgets('collapsed saved activity defers tool detail preparation', (
    tester,
  ) async {
    final arguments = List.generate(40, (_) => _Arguments());
    final timeline = project([
      for (var i = 0; i < arguments.length; i++)
        {
          'id': i + 1,
          'role': 'tool',
          'tool_name': 'web_search',
          'tool_call_id': 'call-$i',
          'content': 'Historical result $i',
          'args': arguments[i],
        },
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ProfileToolActivitySection(
              section: timeline.sections.single,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Activity · 40 tools'), findsOneWidget);
    expect(arguments.every((args) => args.reads == 0), isTrue);
    await tester.tap(
      find.textContaining(RegExp(r'^Activity(?: · \d+ tools?)?$')),
    );
    await tester.pumpAndSettle();
    expect(arguments.every((args) => args.reads > 0), isTrue);
    await tester.tap(
      find.textContaining(RegExp(r'^Activity(?: · \d+ tools?)?$')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.textContaining(RegExp(r'^Activity(?: · \d+ tools?)?$')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Timeline'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('viewport prepares nearby bodies and admits more on scroll', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final appPreferences = AppPreferences(preferences);
    final runtimes = WorkspaceRuntimeFixture();
    final host = ProfileHistoryFixture();
    final controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'lazy-preparation',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
      runtimeFactory: runtimes.create,
    );
    addTearDown(() {
      controller.dispose();
      appPreferences.dispose();
    });
    await controller.initialize();
    final chat = await openFixtureChat(
      controller: controller,
      key: ProfileSessionKey(controller.current!.scope, 'chat-0'),
      title: 'Lazy preparation',
    );
    final images = List.generate(100, (_) => _ImageLocation());
    final timeline = project(imageRows(images));
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileTranscript(
            presentation: TranscriptPresentation.capture(
              identity: chat.key,
              reader: chat.reading,
              timeline: timeline,
              needsInput: chat.runtime.needsInput,
              turnAdmissionBlocked: chat.runtime.blocksTurnAdmission,
            ),
            openingContent: chat.runtime.opening
                ? ProfileTranscriptOpening(
                    status: controller.connectionStatus,
                    error: chat.runtime.openingError,
                    onRetry: controller.resumeConnection,
                  )
                : null,
            notificationReading: chat.reading,
            onAnswerRead: (target) =>
                controller.notificationAnswerRead(chat, target),
            onRefreshHistory: () => controller.refreshHistory(chat),
            onLoadOlder: () async {},
            tail: const [],
            messageBuilder: (entry) =>
                SizedBox(height: 100, child: Text(entry.message.text)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final initial = images.where((image) => image.reads > 0).length;
    expect(initial, greaterThan(0));
    expect(initial, lessThan(20));
    expect(images.take(70).every((image) => image.reads == 0), isTrue);
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    scroll.position.jumpTo(3000);
    await tester.pumpAndSettle();
    expect(
      images.where((image) => image.reads > 0).length,
      greaterThan(initial),
    );
    expect(images.take(30).every((image) => image.reads == 0), isTrue);
    expect(tester.takeException(), isNull);
  });
}
