import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/widgets/wing_app_bar.dart';
import 'package:wing/core/widgets/app_drawer.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'package:wing/core/widgets/composer_action_button.dart';
import 'package:wing/core/widgets/chat_intelligence_picker.dart';
import 'package:wing/core/widgets/context_ring.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'helpers/pump_markdown_widget.dart';
import 'profile_workspace_controller_test.dart' show Host;

void main() {
  testWidgets('growing live Markdown has a bounded presentation cadence', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final host = Host();
    final preferences = await SharedPreferences.getInstance();
    final appPreferences = AppPreferences(preferences);
    addTearDown(appPreferences.dispose);
    final controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'live-streaming-work-budget',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    final chat = await controller.createChat(canDispatch: () => true);
    chat.reading.installSavedHistory([
      {'id': 1, 'role': 'assistant', 'content': 'Saved **answer**'},
    ]);
    host.event('a', 'message.start');
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          createBotsSession: () => BotsSession((_) async => const []),
          controller: controller,
        ),
      ),
    );
    await tester.pump();
    await tester.settleMarkdown();
    final field = find.byKey(const Key('profile-message-composer'));
    await tester.showKeyboard(field);
    await tester.pump();
    var liveBuilds = 0;
    var savedBuilds = 0;
    var composerFieldBuilds = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget is TextField &&
          element.widget.key == const Key('profile-message-composer')) {
        composerFieldBuilds++;
      }
      if (element.widget case MarkdownBody(data: final data)) {
        if (data.startsWith('Word')) liveBuilds++;
        if (data.startsWith('Saved')) savedBuilds++;
      }
      previous?.call(element, builtOnce);
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);
    final chunks = [
      for (var chunk = 0; chunk < 120; chunk++)
        '${List.generate(10, (word) => 'Word${chunk * 10 + word}').join(' ')} ',
    ];
    for (var i = 0; i < chunks.length; i++) {
      host.event('a', 'message.delta', {'text': chunks[i]});
      if (i % 4 == 0) await tester.enterText(field, 'New draft $i');
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(chat.reading.streaming, chunks.join());
    expect(chat.composer.observation.text, 'New draft 116');
    await tester.settleMarkdown();
    expect(savedBuilds, 0);
    expect(
      composerFieldBuilds,
      0,
      reason:
          'Answer chunks and draft edits must retain unchanged field chrome.',
    );
    expect(
      liveBuilds,
      lessThanOrEqualTo(14),
      reason:
          '120 deltas in 1.2 seconds need at most one live render per 100ms.',
    );
    // Completion replaces the live tail immediately with the exact full answer.
    host.historyMessages = [
      {'id': 1, 'role': 'assistant', 'content': 'Saved **answer**'},
      {'id': 2, 'role': 'assistant', 'content': chunks.join()},
    ];
    host.event('a', 'message.complete');
    await tester.pump();
    expect(chat.reading.streaming, isEmpty);
    expect(chat.reading.messages.last['content'], chunks.join());
    expect(chat.runtime.execution, ChatExecution.completed);
    expect(chat.composer.observation.text, 'New draft 116');
    await tester.settleMarkdown();
    expect(
      tester
          .widgetList<MarkdownBody>(find.bySubtype<MarkdownBody>())
          .any((body) => body.data == chunks.join()),
      isTrue,
    );
  });

  testWidgets('streaming leaves unchanged saved Markdown unbuilt', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final host = Host();
    final preferences = await SharedPreferences.getInstance();
    final appPreferences = AppPreferences(preferences);
    addTearDown(appPreferences.dispose);
    final controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'streaming-work-budget',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    final chat = await controller.createChat(canDispatch: () => true);
    chat.reading.installSavedHistory([
      for (var i = 1; i <= 20; i++)
        {
          'id': i,
          'role': i.isEven ? 'assistant' : 'user',
          'content': 'Saved message $i with **formatted** content.',
        },
    ]);
    host.event('a', 'message.start');
    host.event('a', 'message.delta', {'text': 'Live answer'});
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          createBotsSession: () => BotsSession((_) async => const []),
          controller: controller,
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.settleMarkdown();
    expect(
      find.byWidgetPredicate((w) => w is ProfileMessage && !w.streaming),
      findsWidgets,
    );
    var savedBuilds = 0;
    var unchangedControlBuilds = 0;
    var headerBuilds = 0, drawerBuilds = 0, frameBuilds = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget is WingAppBar) headerBuilds++;
      if (element.widget is Scaffold) frameBuilds++;
      if (element.widget is AppDrawer) drawerBuilds++;
      if (element.widget is ComposerActionButton ||
          element.widget is ChatIntelligenceButton ||
          element.widget is ContextRing) {
        unchangedControlBuilds++;
      }
      if (element.widget case MarkdownBody(
        data: final text,
      ) when text.startsWith('Saved message')) {
        savedBuilds++;
      }
      previous?.call(element, builtOnce);
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);
    for (var i = 0; i < 30; i++) {
      host.event('a', 'message.delta', {'text': '.'});
      await tester.pump(const Duration(milliseconds: 16));
    }
    debugPrint('Streaming 30 deltas: $savedBuilds saved Markdown builds');
    expect(chat.reading.streaming, 'Live answer${'.' * 30}');
    expect(
      savedBuilds,
      0,
      reason: 'New answer text must not re-render unchanged saved Markdown.',
    );
    expect(
      unchangedControlBuilds,
      0,
      reason: 'Streaming must retain unchanged composer controls.',
    );
    expect(
      headerBuilds,
      0,
      reason: 'Answer growth does not change the header.',
    );
    expect(
      drawerBuilds,
      0,
      reason: 'Answer growth does not change navigation.',
    );
    expect(
      frameBuilds,
      0,
      reason: 'Answer growth does not rebuild the page frame.',
    );
    await tester.pump(const Duration(milliseconds: 200));
  });
}
