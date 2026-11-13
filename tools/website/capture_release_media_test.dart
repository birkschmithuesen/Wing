// Manual website exports: production widgets with authored fixture data.
// Run with flutter test --no-pub tools/website/capture_release_media_test.dart.
// Desktop capture requires DESKTOP_CAPTURE, an existing 2160x1080 capture
// described in internal/docs/WEBSITE.md. No live backend is contacted.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/administration/admin_scheduled_task_detail_page.dart';
import 'package:wing/core/screens/administration/admin_scheduled_task_editor_page.dart';
import 'package:wing/core/screens/administration/admin_scheduled_tasks_page.dart';
import 'package:wing/core/screens/bots/bot_screen_view.dart';
import 'package:wing/core/services/bot_screen_session.dart';
import 'package:wing/core/services/bot_screen_window.dart';
import 'package:wing/core/services/scheduled_tasks_controller.dart';
import 'package:wing/core/services/scheduled_tasks_repository.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/screens/connection_setup_screen.dart';
import 'package:wing/core/screens/administration/admin_skills_page.dart';
import 'package:wing/core/services/connection_setup_session.dart';
import 'package:wing/core/services/hermes_cloud.dart';
import 'package:wing/core/services/profile_skills_session.dart';
import '../../test/helpers/pump_markdown_widget.dart';
import '../../test/support/administration_fixture.dart';
import '../../test/support/connection_probe_fixture.dart';
import '../../test/support/bot_display_fixture.dart';
import '../../test/support/scheduled_tasks_fixture.dart';

void main() {
  final boundary = GlobalKey();
  setUpAll(() async {
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
      'monospace': 'build/studio-mono.ttf',
      'WingIcons': 'assets/fonts/wing-icons.ttf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(entry.value).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });

  Future<void> show(
    WidgetTester tester,
    Widget child, {
    bool landscape = false,
  }) async {
    tester.view.physicalSize = landscape
        ? const Size(844, 390)
        : const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: wingTheme(Brightness.dark),
          home: child,
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> export(WidgetTester tester, String name) async {
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory('build/website-release-media')
        ..createSync(recursive: true);
      await File(
        '${directory.path}/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('export connection setup workflow', (tester) async {
    final probe = ConnectionProbeFixture();
    await show(
      tester,
      ConnectionSetupScreen(
        createSession: () => ConnectionSetupSession(
          initialAccess: null,
          onSaveIcon: null,
          savedConnections: () => const [],
          cloud: HermesCloud(),
          createProbe: (_) => probe,
          onSave: (connection) async => connection,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final context = tester.element(find.byType(ConnectionSetupScreen));
      for (final image in tester.widgetList<Image>(find.byType(Image))) {
        await precacheImage(image.image, context);
      }
    });
    await tester.pumpAndSettle();
    await export(tester, 'connection-choose-dark');
    await tester.tap(find.text('Use an address'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('connection-address')),
      'https://hermes.example.com',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await export(tester, 'connection-address-dark');
    await tester.ensureVisible(find.text('Next'));
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('connection-username')),
      'alex',
    );
    await tester.enterText(
      find.byKey(const Key('connection-password')),
      'demo-password',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.ensureVisible(find.text('Check connection'));
    await tester.tap(find.text('Check connection'));
    await tester.pumpAndSettle();
    expect(
      find.text('Connection verified. Select Next to continue.'),
      findsOneWidget,
    );
    await export(tester, 'connection-check-dark');
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Connection verified'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('connection-name')),
      'My Hermes',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await export(tester, 'connection-verified-dark');
  });

  testWidgets('export skill reader and editor', (tester) async {
    const instructions = '''---
name: research
description: Turn a question into a sourced briefing.
---
# Research

Start with the question the reader needs answered.

## Gather evidence

- Read original sources before summaries.
- Check when each source was published.
- Keep a link beside each useful finding.

## Write the briefing

Lead with the answer. Explain the evidence and call out anything still uncertain.

End with a short list of next steps.
''';
    final fixture = AdministrationFixture();
    fixture.override = (_, path, query, _) async => switch (path) {
      'skills' => {
        'data': [
          {
            'name': 'research',
            'description': 'Turn a question into a sourced briefing.',
            'provenance': 'agent',
            'locked': false,
            'usage': 12,
            'enabled': true,
          },
        ],
      },
      'profiles' => {
        'profiles': [
          {'name': 'personal', 'path': '/workspace'},
        ],
      },
      'fs/list' => {
        'entries': switch (query['path']) {
          '/workspace' => [
            {
              'name': 'skills',
              'path': '/workspace/skills',
              'isDirectory': true,
            },
          ],
          '/workspace/skills' => [
            {
              'name': '.usage.json',
              'path': '/workspace/skills/.usage.json',
              'isDirectory': false,
            },
          ],
          _ => [],
        },
      },
      'fs/read-text' => {
        'binary': false,
        'truncated': false,
        'text': '{"research":{"use_count":12,"patch_count":2}}',
      },
      'analytics/usage' => {
        'skills': {
          'top_skills': [
            {'skill': 'research', 'view_count': 12},
          ],
        },
      },
      'skills/content' => {
        'name': 'research',
        'content': instructions,
        'path': '/workspace/skills/research/SKILL.md',
      },
      _ => throw StateError('Unexpected request $path'),
    };
    final session = ProfileSkillsSession.library(
      fixture.server.profile('personal'),
    );
    addTearDown(session.dispose);
    await session.refresh();
    final route = session.openSkill(session.state.installed.single);
    await show(tester, AdminSkillDetail(session: session, route: route));
    await tester.pumpAndSettle();
    await tester.settleMarkdown();
    await export(tester, 'skill-reader-dark');
    await tester.tap(find.byTooltip('Skill actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit instructions'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      '$instructions\nUse plain language and keep the briefing under 500 words.\n',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.drag(find.byType(TextField), const Offset(0, 600));
    await tester.pumpAndSettle();
    await export(tester, 'skill-editor-dark');
    expect(fixture.requests.every((request) => request.$1 == 'GET'), true);
  });

  testWidgets('export schedule list, filled editor and recent runs', (
    tester,
  ) async {
    // This manual test lives under tools/ so it is not run by the app suite.
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final fixture = ScheduledTasksFixture();
    fixture.runRows.add({
      'id': 'cron_output:morning:20260918_090000',
      'source': 'cron_output',
      'title': 'COMPLETED · Script-only run',
      'preview': 'The report was saved on the server.',
      'started_at': 1789700000,
    });
    final controller = ScheduledTasksController(
      ScheduledTasksRepository(fixture.profile),
      prefs,
    );
    addTearDown(controller.dispose);
    await controller.refresh();
    await show(
      tester,
      AdminScheduledTasksPage(
        profile: fixture.profile,
        acquireController: () =>
            ScheduledTasksController.acquire(fixture.profile, prefs),
        onOpenSession: (_) async {},
      ),
    );
    await tester.pumpAndSettle();
    await export(tester, 'scheduled-tasks-dark');
    await show(
      tester,
      AdminScheduledTaskEditorPage(
        controller: controller,
        original: controller.task('morning'),
      ),
    );
    await tester.pumpAndSettle();
    await export(tester, 'scheduled-task-editor-dark');
    await show(
      tester,
      AdminScheduledTaskDetailPage(
        controller: controller,
        initial: controller.task('morning')!,
        onOpenSession: (_) async {},
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('COMPLETED · Script-only run'),
      200,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('task-detail-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await export(tester, 'scheduled-task-runs-dark');
  });

  testWidgets('export desktop takeover with current production controls', (
    tester,
  ) async {
    final path = Platform.environment['DESKTOP_CAPTURE'];
    expect(
      path,
      isNotNull,
      reason: 'Supply the saved desktop source documented in WEBSITE.md.',
    );
    late Uint8List pixels;
    const width = 1492, height = 923;
    await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(
        await File(path!).readAsBytes(),
      );
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 2160);
      expect(frame.image.height, 1080);
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawImageRect(
        frame.image,
        Rect.fromLTWH(395, 11, width.toDouble(), height.toDouble()),
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint(),
      );
      final picture = recorder.endRecording();
      final desktop = await picture.toImage(width, height);
      final rgba = await desktop.toByteData(format: ui.ImageByteFormat.rawRgba);
      pixels = Uint8List.fromList(rgba!.buffer.asUint8List());
      desktop.dispose();
      picture.dispose();
      frame.image.dispose();
      codec.dispose();
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(BotScreenWindow.channel, (_) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(BotScreenWindow.channel, null),
    );
    final fixture = DisplayFixture();
    final session = BotScreenSession(
      fixture.repository,
      (await fixture.roster.repository.bots()).first,
    );
    await show(
      tester,
      BotScreenView(
        createSession: () => session,
        conversation: session,
        readConversation: () => [],
        readRequest: () => 'Please check the desktop, then hand control back.',
        sendMessage: (_) async {},
      ),
      landscape: true,
    );
    for (var i = 0; i < 200 && !session.connected; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(session.connected, true);
    final header = ByteData(28)
      ..setUint16(2, 2)
      ..setUint16(8, width)
      ..setUint16(10, height)
      ..setInt32(12, -223)
      ..setUint16(20, width)
      ..setUint16(22, height);
    fixture.peers.single.add([...header.buffer.asUint8List(), ...pixels]);
    for (var i = 0; i < 200; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      if (tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((w) => w.image?.width == width)) {
        break;
      }
    }
    expect(
      tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((w) => w.image?.width == width),
      true,
    );
    await tester.tap(find.byTooltip('Take control'));
    await tester.pumpAndSettle();
    expect(session.controlling, true);
    await export(tester, 'bot-screen-control-dark');
    await tester.pumpWidget(const SizedBox());
  });
}
