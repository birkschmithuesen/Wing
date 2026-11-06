import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'dart:convert';
import 'dart:async';
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
import 'package:wing/core/screens/administration/scheduled_task_widgets.dart';
import 'package:wing/core/services/scheduled_tasks_controller.dart';
import 'package:wing/core/services/scheduled_tasks_repository.dart';
import 'package:wing/core/theme/profile_workspace_theme.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_selection_tile.dart';
import 'support/scheduled_tasks_fixture.dart';

void main() {
  const capture = bool.fromEnvironment('CAPTURE_SCHEDULED_TASKS');
  setUpAll(() async {
    final config = File('.dart_tool/package_config.json').absolute;
    final packages =
        (jsonDecode(await config.readAsString()) as Map)['packages'] as List;
    final flutter = packages.cast<Map>().singleWhere(
      (package) => package['name'] == 'flutter',
    );
    final packageRoot = Directory.fromUri(
      config.uri.resolve(flutter['rootUri'] as String),
    );
    final sdkRoot = packageRoot.parent.parent;
    final root = '${sdkRoot.path}/bin/cache/artifacts/material_fonts';
    for (final f in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(f.key)..addFont(
            File(
              '$root/${f.value}',
            ).readAsBytes().then((bytes) => bytes.buffer.asByteData()),
          ))
          .load();
    }
  });
  late ScheduledTasksFixture fixture;
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    fixture = ScheduledTasksFixture();
  });

  Future<void> show(
    WidgetTester tester,
    Widget page, {
    Brightness brightness = Brightness.light,
    WorkspaceAccent accent = WorkspaceAccent.teal,
    double width = 390,
    double scale = 1,
    double keyboard = 0,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: profileWorkspaceTheme(wingTheme(brightness), accent: accent),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: RepaintBoundary(
            key: const ValueKey('task-capture'),
            child: child!,
          ),
        ),
        home: page,
      ),
    );
    await tester.pumpAndSettle();
  }

  Widget list({Future<void> Function(ProfileSessionKey)? open}) =>
      AdminScheduledTasksPage(
        profile: fixture.profile,
        acquireController: () =>
            ScheduledTasksController.acquire(fixture.profile, prefs),
        onOpenSession: open ?? (_) async {},
      );
  Future<ScheduledTasksController> controller() async {
    final c = ScheduledTasksController(
      ScheduledTasksRepository(fixture.profile),
      prefs,
    );
    addTearDown(c.dispose);
    await c.refresh();
    return c;
  }

  Future<ScheduledTasksController> openTaskEditor(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    double width = 390,
    double scale = 1,
  }) async {
    final retained = ScheduledTasksController.acquire(fixture.profile, prefs);
    addTearDown(retained.release);
    await retained.refresh();
    await show(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => AdminTaskRoute(
                  profile: fixture.profile,
                  acquireController: () =>
                      ScheduledTasksController.acquire(fixture.profile, prefs),
                  title: 'Edit task',
                  taskId: 'morning',
                  builder: (controller, task) => AdminScheduledTaskEditorPage(
                    controller: controller,
                    original: task,
                  ),
                ),
              ),
            ),
            child: const Text('Open task editor'),
          ),
        ),
      ),
      brightness: brightness,
      width: width,
      scale: scale,
    );
    await tester.tap(find.text('Open task editor'));
    await tester.pumpAndSettle();
    return retained;
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('task-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/scheduled-tasks-review/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('Stop run pending and settlement ${brightness.name} $scale', (
        tester,
      ) async {
        fixture.jobs['morning'] = {
          ...taskJson(state: 'running'),
          'latest_execution': {
            'id': 'later',
            'status': 'rejected',
            'error': 'Already running',
          },
        };
        final c = await controller();
        await show(
          tester,
          AdminScheduledTaskDetailPage(
            controller: c,
            initial: c.task('morning')!,
            onOpenSession: (_) async {},
          ),
          brightness: brightness,
          scale: scale,
          width: scale == 2 ? 320 : 390,
        );
        fixture.gate = Completer<void>();
        await tester.tap(find.byTooltip('Stop run'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.bySemanticsLabel('Updating task'), findsWidgets);
        await screenshot(tester, 'cancel-held-${brightness.name}-$scale');
        expect(fixture.mutations, 1);
        fixture.gate!.complete();
        await tester.pumpAndSettle();
        expect(c.notice, contains('Stop requested'));
        expect(c.task('morning')!.running, isTrue);
        expect(fixture.jobs['morning']!['enabled'], isTrue);
        await screenshot(tester, 'cancel-requested-${brightness.name}-$scale');
        fixture.jobs['morning']!['live_execution'] = null;
        fixture.jobs['morning']!['state'] = 'scheduled';
        await c.refresh();
        await tester.pumpAndSettle();
        expect(find.byTooltip('Stop run'), findsNothing);
        expect(tester.takeException(), isNull);
      });
      testWidgets('task policy and room controls ${brightness.name} $scale', (
        tester,
      ) async {
        fixture.rooms.add({
          'room_id': 'release',
          'name': 'Release team',
          'members': [],
        });
        final c = await controller();
        await show(
          tester,
          AdminScheduledTaskEditorPage(
            controller: c,
            original: c.task('morning'),
          ),
          brightness: brightness,
          scale: scale,
          width: scale == 2 ? 320 : 390,
        );
        final zone = find.widgetWithText(TextFormField, 'Schedule timezone');
        await tester.scrollUntilVisible(
          zone,
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.enterText(zone, 'Asia/Singapore');
        tester.testTextInput.hide();
        await tester.scrollUntilVisible(
          find.text('Hermes default'),
          150,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        final missedSelector = find.ancestor(
          of: find.text('Missed runs'),
          matching: find.byWidgetPredicate((widget) => widget is DropdownMenu),
        );
        await tester.tap(
          find
              .descendant(
                of: missedSelector,
                matching: find.byIcon(Icons.arrow_drop_down),
              )
              .hitTestable(),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Run one catch-up').hitTestable());
        await tester.pumpAndSettle();
        final grace = find.widgetWithText(TextFormField, 'Late window (min)');
        await tester.scrollUntilVisible(
          grace,
          180,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.enterText(grace, '0');
        tester.testTextInput.hide();
        await tester.pumpAndSettle();
        await screenshot(tester, 'policy-${brightness.name}-$scale');
        await tester.scrollUntilVisible(
          find.text('Release team'),
          220,
          scrollable: find.byType(Scrollable).first,
        );
        for (
          var attempt = 0;
          attempt < 12 &&
              find.text('Release team').hitTestable().evaluate().isEmpty;
          attempt++
        ) {
          await tester.drag(find.byType(ListView).first, const Offset(0, -180));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('Release team').hitTestable());
        await tester.pumpAndSettle();
        await screenshot(tester, 'room-delivery-${brightness.name}-$scale');
        await tester.tap(find.byTooltip('Save changes'));
        await tester.pumpAndSettle();
        expect(fixture.jobs['morning']!['timezone'], 'Asia/Singapore');
        expect(fixture.jobs['morning']!['grace_minutes'], 0);
        expect(fixture.jobs['morning']!['catch_up'], true);
        expect(
          fixture.jobs['morning']!['deliver'],
          'local,room:release@default',
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('Stop failure is visible and leaves the live execution intact', (
    tester,
  ) async {
    fixture.jobs['morning'] = taskJson(state: 'running');
    final c = await controller();
    await show(
      tester,
      AdminScheduledTaskDetailPage(
        controller: c,
        initial: c.task('morning')!,
        onOpenSession: (_) async {},
      ),
    );
    fixture.mutationError = const TaskPreflightFailure('Stop refused.');
    await tester.tap(find.byTooltip('Stop run'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Stop refused'), findsWidgets);
    expect(c.task('morning')!.running, isTrue);
    expect(c.busy, isEmpty);
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'running schedule pulses in its existing status position ${brightness.name} $scale',
        (tester) async {
          fixture.jobs['morning'] = taskJson(state: 'running');
          await show(
            tester,
            list(),
            brightness: brightness,
            width: scale == 1 ? 390 : 320,
            scale: scale,
          );
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(find.text('Working on it now'), findsOneWidget);
          await screenshot(tester, 'working-list-${brightness.name}-$scale');
          final c = await controller();
          await show(
            tester,
            AdminScheduledTaskDetailPage(
              controller: c,
              initial: c.task('morning')!,
              onOpenSession: (_) async {},
            ),
            brightness: brightness,
            width: scale == 1 ? 390 : 320,
            scale: scale,
          );
          expect(find.byType(StudioLoading), findsOneWidget);
          await screenshot(tester, 'working-detail-${brightness.name}-$scale');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('search filters tasks and opens a scoped run conversation', (
    tester,
  ) async {
    ProfileSessionKey? opened;
    await show(tester, list(open: (key) async => opened = key));
    await tester.enterText(find.byType(TextField), 'Morning');
    await tester.pumpAndSettle();
    expect(find.text('Weekly review'), findsNothing);
    await tester.tap(find.text('Morning briefing'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Your morning briefing'),
      350,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('task-detail-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(find.text('Your morning briefing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Your morning briefing'));
    await tester.pumpAndSettle();
    expect(opened!.workspace.profileName, 'personal');
    expect(opened!.sessionId, 'cron_morning_123');
    expect(tester.takeException(), null);
  });
  testWidgets('manual creation sends instructions, scope and server delivery', (
    tester,
  ) async {
    await show(tester, list());
    await tester.tap(find.text('New task'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name (optional)'),
      'Daily digest',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Instructions'),
      'Summarize my calendar.',
    );
    await tester.tap(find.byTooltip('Create task'));
    await tester.pumpAndSettle();
    final request = fixture.admin.requests.firstWhere(
      (r) => r.$1 == 'POST' && r.$2 == 'cron/jobs',
    );
    expect(request.$3['profile'], 'personal');
    expect(request.$4!['name'], 'Daily digest');
    expect(request.$4!['prompt'], 'Summarize my calendar.');
    expect(request.$4!['schedule'], '0 9 * * *');
    expect(request.$4!['deliver'], 'local');
    expect(find.text('Scheduled tasks'), findsOneWidget);
    expect(tester.takeException(), null);
  });
  testWidgets('task model choice stays in the draft until task Save', (
    tester,
  ) async {
    final c = await controller();
    await show(tester, AdminScheduledTaskEditorPage(controller: c));
    await tester.scrollUntilVisible(
      find.text('Profile default'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Profile default').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Profile default'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('model-provider-anthropic')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('model-anthropic-claude-sonnet-4-5')),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Use in task'), findsOneWidget);
    expect(fixture.mutations, 0);
    await tester.tap(find.byTooltip('Use in task'));
    await tester.pumpAndSettle();
    expect(fixture.mutations, 0);

    await tester.scrollUntilVisible(
      find.widgetWithText(TextFormField, 'Instructions'),
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Instructions'),
      'Summarize my calendar.',
    );
    await tester.tap(find.byTooltip('Create task'));
    await tester.pumpAndSettle();
    final request = fixture.admin.requests.firstWhere(
      (r) => r.$1 == 'POST' && r.$2 == 'cron/jobs',
    );
    expect(request.$4!['model'], 'claude-sonnet-4-5');
    expect(request.$4!['provider'], 'anthropic');
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'task route refresh preserves externally changed fields on name-only save',
    (tester) async {
      fixture.jobs['morning']!.addAll({
        'prompt': 'Opening instructions',
        'schedule': {'kind': 'interval', 'minutes': 30},
        'model': 'claude-sonnet-4-5',
        'provider': 'anthropic',
      });
      final retained = ScheduledTasksController.acquire(fixture.profile, prefs);
      addTearDown(retained.release);
      await retained.refresh();
      await show(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => AdminTaskRoute(
                    profile: fixture.profile,
                    acquireController: () => ScheduledTasksController.acquire(
                      fixture.profile,
                      prefs,
                    ),
                    title: 'Edit task',
                    taskId: 'morning',
                    builder: (controller, selectedTask) =>
                        AdminScheduledTaskEditorPage(
                          controller: controller,
                          original: selectedTask,
                        ),
                  ),
                ),
              ),
              child: const Text('Open task editor'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open task editor'));
      await tester.pumpAndSettle();

      fixture.jobs['morning']!.addAll({
        'prompt': 'New instructions from another client',
        'schedule': {'kind': 'interval', 'minutes': 45},
        'deliver': 'telegram',
        'model': 'new-external-model',
        'provider': 'openai',
      });
      await retained.refresh();
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name (optional)'),
        'Only edited name',
      );
      await tester.tap(find.byTooltip('Save changes'));
      await tester.pumpAndSettle();

      final writes = fixture.admin.requests
          .where((r) => r.$1 == 'PUT')
          .toList();
      expect(writes, hasLength(1));
      expect(writes.single.$4!['updates'], {'name': 'Only edited name'});
      expect(
        fixture.jobs['morning']!['prompt'],
        'New instructions from another client',
      );
      expect(fixture.jobs['morning']!['schedule'], {
        'kind': 'interval',
        'minutes': 45,
      });
      expect(fixture.jobs['morning']!['deliver'], 'telegram');
      expect(fixture.jobs['morning']!['model'], 'new-external-model');
      expect(fixture.jobs['morning']!['provider'], 'openai');
      expect(find.text('Open task editor'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'task conflict review keeps the draft and explicitly recovers in the pushed editor',
    (tester) async {
      final retained = ScheduledTasksController.acquire(fixture.profile, prefs);
      addTearDown(retained.release);
      await retained.refresh();
      await show(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => AdminTaskRoute(
                    profile: fixture.profile,
                    acquireController: () => ScheduledTasksController.acquire(
                      fixture.profile,
                      prefs,
                    ),
                    title: 'Edit task',
                    taskId: 'morning',
                    builder: (controller, selectedTask) =>
                        AdminScheduledTaskEditorPage(
                          controller: controller,
                          original: selectedTask,
                        ),
                  ),
                ),
              ),
              child: const Text('Open task editor'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open task editor'));
      await tester.pumpAndSettle();
      final name = find.widgetWithText(TextFormField, 'Name (optional)');
      await tester.enterText(name, 'My retained name');
      fixture.jobs['morning']!.addAll({
        'name': 'Name from another client',
        'prompt': 'New unedited instructions',
      });
      await retained.refresh();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Save changes'));
      await tester.pumpAndSettle();

      // Real refusal/draft/route prerequisites precede the missing recovery.
      expect(fixture.mutations, 0);
      expect(fixture.jobs['morning']!['name'], 'Name from another client');
      expect(
        tester.widget<TextFormField>(name).controller!.text,
        'My retained name',
      );
      expect(find.byType(AdminScheduledTaskEditorPage), findsOneWidget);
      expect(find.textContaining('changed on Hermes'), findsOneWidget);
      expect(find.text('Review changes').hitTestable(), findsOneWidget);

      await tester.tap(find.text('Review changes'));
      await tester.pumpAndSettle();
      expect(find.text('My retained name'), findsWidgets);
      expect(find.text('Name from another client'), findsOneWidget);
      await tester.tap(find.text('Keep mine'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Apply decisions'));
      await tester.pumpAndSettle();
      expect(fixture.mutations, 0);
      expect(
        tester.widget<TextFormField>(name).controller!.text,
        'My retained name',
      );
      await tester.tap(find.byTooltip('Save changes'));
      await tester.pumpAndSettle();

      final writes = fixture.admin.requests
          .where((r) => r.$1 == 'PUT')
          .toList();
      expect(writes, hasLength(1));
      expect(writes.single.$3['profile'], 'personal');
      expect(writes.single.$4!['updates'], {'name': 'My retained name'});
      expect(fixture.jobs['morning']!['prompt'], 'New unedited instructions');
      expect(find.text('Open task editor'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'cancelling task conflict review keeps dirty fields and still refuses the stale baseline',
    (tester) async {
      await openTaskEditor(tester);
      final name = find.widgetWithText(TextFormField, 'Name (optional)');
      await tester.enterText(name, 'My draft');
      fixture.jobs['morning']!['name'] = 'Remote name';
      await tester.tap(find.byTooltip('Save changes'));
      await tester.pumpAndSettle();
      expect(fixture.mutations, 0);
      await tester.tap(find.text('Review changes'));
      await tester.pumpAndSettle();
      expect(find.text('Remote name'), findsOneWidget);
      await tester.tap(find.text('Keep mine'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Cancel').last);
      await tester.pumpAndSettle();
      expect(find.text('Review task changes'), findsNothing);
      expect(tester.widget<TextFormField>(name).controller!.text, 'My draft');
      expect(fixture.mutations, 0);
      await tester.tap(find.byTooltip('Save changes'));
      await tester.pumpAndSettle();
      expect(fixture.mutations, 0);
      expect(find.textContaining('changed on Hermes'), findsOneWidget);
      expect(find.byType(AdminScheduledTaskEditorPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'task conflict Use server adopts only the reviewed field before Save',
    (tester) async {
      await openTaskEditor(tester);
      final name = find.widgetWithText(TextFormField, 'Name (optional)');
      final prompt = find.widgetWithText(TextFormField, 'Instructions');
      await tester.enterText(name, 'My name');
      await tester.ensureVisible(prompt);
      await tester.enterText(prompt, 'My retained instructions');
      fixture.jobs['morning']!['name'] = 'Remote name';
      await tester.tap(find.byTooltip('Save changes'));
      await tester.pumpAndSettle();
      expect(fixture.mutations, 0);
      await tester.tap(find.text('Review changes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use server'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Apply decisions'));
      await tester.pumpAndSettle();
      expect(fixture.mutations, 0);
      expect(
        tester.widget<TextFormField>(name).controller!.text,
        'Remote name',
      );
      expect(
        tester.widget<TextFormField>(prompt).controller!.text,
        'My retained instructions',
      );
      await tester.tap(find.byTooltip('Save changes'));
      await tester.pumpAndSettle();
      final write = fixture.admin.requests.singleWhere((r) => r.$1 == 'PUT');
      expect(write.$4!['updates'], {'prompt': 'My retained instructions'});
      expect(fixture.jobs['morning']!['name'], 'Remote name');
      expect(find.text('Open task editor'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'script-only task review explains and explicitly discards unsupported instructions',
    (tester) async {
      await openTaskEditor(tester);
      final name = find.widgetWithText(TextFormField, 'Name (optional)');
      final prompt = find.widgetWithText(TextFormField, 'Instructions');
      await tester.enterText(name, 'My name');
      await tester.ensureVisible(prompt);
      await tester.enterText(prompt, 'My retained instructions');
      fixture.jobs['morning']!.addAll({
        'name': 'Remote name',
        'no_agent': true,
        'script': 'server-owned.sh',
      });
      await tester.tap(find.byTooltip('Save changes'));
      await tester.pumpAndSettle();
      expect(fixture.mutations, 0);
      expect(
        tester.widget<TextFormField>(prompt).controller!.text,
        'My retained instructions',
      );
      await tester.tap(find.text('Review changes'));
      await tester.pumpAndSettle();
      final keepPrompt = find.byKey(
        const ValueKey('task-conflict-prompt-mine'),
      );
      await tester.ensureVisible(keepPrompt);
      await tester.pumpAndSettle();
      expect(tester.widget<StudioSelectionTile>(keepPrompt).onChanged, isNull);
      expect(
        find.textContaining('discard your instructions edit'),
        findsOneWidget,
      );
      final serverPrompt = find.byKey(
        const ValueKey('task-conflict-prompt-server'),
      );
      await tester.ensureVisible(serverPrompt);
      await tester.tap(serverPrompt);
      await tester.pump();
      final keepName = find.byKey(const ValueKey('task-conflict-name-mine'));
      await tester.ensureVisible(keepName);
      await tester.tap(keepName);
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton && widget.tooltip == 'Apply decisions',
              ),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byTooltip('Apply decisions'));
      await tester.pumpAndSettle();
      expect(find.text('Review task changes'), findsNothing);
      expect(fixture.mutations, 0);
      expect(tester.widget<TextFormField>(name).controller!.text, 'My name');
      expect(tester.widget<TextFormField>(prompt).enabled, false);
      await tester.tap(find.byTooltip('Save changes'));
      await tester.pumpAndSettle();
      final write = fixture.admin.requests.singleWhere((r) => r.$1 == 'PUT');
      expect(write.$4!['updates'], {'name': 'My name'});
      expect(fixture.jobs['morning']!['no_agent'], true);
      expect(fixture.jobs['morning']!['script'], 'server-owned.sh');
      expect(find.text('Open task editor'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dirty pushed task Back stays or explicitly discards without any write',
    (tester) async {
      await openTaskEditor(tester);
      final name = find.widgetWithText(TextFormField, 'Name (optional)');
      await tester.enterText(name, 'Unsaved name');
      await tester.pump();
      final guard = find.descendant(
        of: find.byType(AdminScheduledTaskEditorPage),
        matching: find.byWidgetPredicate((widget) => widget is PopScope),
      );
      expect(tester.widget<PopScope>(guard).canPop, false);
      expect(
        tester.widget<TextFormField>(name).controller!.text,
        'Unsaved name',
      );
      expect(fixture.mutations, 0);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Discard your changes?'), findsOneWidget);
      expect(fixture.mutations, 0);
      await tester.tap(find.byTooltip('Cancel').last);
      await tester.pumpAndSettle();
      expect(find.byType(AdminScheduledTaskEditorPage), findsOneWidget);
      expect(
        tester.widget<TextFormField>(name).controller!.text,
        'Unsaved name',
      );
      expect(fixture.jobs['morning']!['name'], 'Morning briefing');
      expect(fixture.mutations, 0);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Discard changes'));
      await tester.pumpAndSettle();
      expect(find.byType(AdminScheduledTaskEditorPage), findsNothing);
      expect(find.text('Open task editor'), findsOneWidget);
      expect(fixture.jobs['morning']!['name'], 'Morning briefing');
      expect(fixture.mutations, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'task conflict review is reachable in ${brightness.name} at ${scale}x',
        (tester) async {
          await openTaskEditor(
            tester,
            brightness: brightness,
            width: 320,
            scale: scale,
          );
          final name = find.widgetWithText(TextFormField, 'Name (optional)');
          await tester.ensureVisible(name);
          await tester.enterText(name, 'My draft');
          fixture.jobs['morning']!['name'] = 'Remote name';
          await tester.tap(find.byTooltip('Save changes'));
          await tester.pumpAndSettle();
          final review = find.text('Review changes').hitTestable();
          expect(review, findsOneWidget);
          expect(fixture.mutations, 0);
          await tester.tap(review);
          await tester.pumpAndSettle();
          final mine = find.byKey(const ValueKey('task-conflict-name-mine'));
          await tester.ensureVisible(mine);
          await tester.pumpAndSettle();
          expect(mine.hitTestable(), findsOneWidget);
          expect(tester.getSize(mine).height, greaterThanOrEqualTo(48));
          await tester.tap(mine);
          await tester.pumpAndSettle();
          final apply = find.byTooltip('Apply decisions').hitTestable();
          expect(apply, findsOneWidget);
          expect(tester.takeException(), isNull);
          await screenshot(tester, 'conflict-${brightness.name}-${scale}x');
          await tester.tap(apply);
          await tester.pumpAndSettle();
          expect(fixture.mutations, 0);
          await tester.ensureVisible(name);
          expect(
            tester.widget<TextFormField>(name).controller!.text,
            'My draft',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'task editor keeps the draft when another client changes the edited field',
    (tester) async {
      final retained = ScheduledTasksController.acquire(fixture.profile, prefs);
      addTearDown(retained.release);
      await show(
        tester,
        AdminTaskRoute(
          profile: fixture.profile,
          acquireController: () =>
              ScheduledTasksController.acquire(fixture.profile, prefs),
          title: 'Edit task',
          taskId: 'morning',
          builder: (controller, selectedTask) => AdminScheduledTaskEditorPage(
            controller: controller,
            original: selectedTask,
          ),
        ),
      );
      fixture.jobs['morning']!['name'] = 'Name from another client';
      await retained.refresh();
      await tester.pumpAndSettle();
      final name = find.widgetWithText(TextFormField, 'Name (optional)');
      await tester.enterText(name, 'My unsaved name');
      await tester.tap(find.byTooltip('Save changes'));
      await tester.pumpAndSettle();

      expect(fixture.mutations, 0);
      expect(fixture.jobs['morning']!['name'], 'Name from another client');
      expect(find.byType(AdminScheduledTaskEditorPage), findsOneWidget);
      expect(find.textContaining('changed on Hermes'), findsOneWidget);
      expect(
        tester.widget<TextFormField>(name).controller!.text,
        'My unsaved name',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'edit name does not re-anchor schedule or erase advanced settings',
    (tester) async {
      fixture.jobs['morning']!['schedule'] = {
        'kind': 'interval',
        'minutes': 30,
      };
      fixture.jobs['morning']!['script'] = 'brief.sh';
      final c = await controller();
      await show(
        tester,
        AdminScheduledTaskEditorPage(
          controller: c,
          original: c.task('morning'),
        ),
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name (optional)'),
        'New title',
      );
      await tester.tap(find.byTooltip('Save changes'));
      await tester.pumpAndSettle();
      final changes =
          fixture.admin.requests.firstWhere((r) => r.$1 == 'PUT').$4!['updates']
              as Map;
      expect(changes, {'name': 'New title'});
      expect(fixture.jobs['morning']!['script'], 'brief.sh');
    },
  );
  testWidgets('paused run requires explicit resume-and-run confirmation', (
    tester,
  ) async {
    final c = await controller();
    await show(
      tester,
      AdminScheduledTaskDetailPage(
        controller: c,
        initial: c.task('review')!,
        onOpenSession: (_) async {},
      ),
    );
    await tester.tap(find.byTooltip('Resume and run').hitTestable().last);
    await tester.pumpAndSettle();
    expect(find.text('Resume and run?'), findsOneWidget);
    expect(fixture.mutations, 0);
    await tester.tap(find.byTooltip('Cancel').last);
    await tester.pumpAndSettle();
    expect(fixture.mutations, 0);
    await tester.tap(find.byTooltip('Resume and run').hitTestable().last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Resume and run').hitTestable().last);
    await tester.pumpAndSettle();
    expect(fixture.mutations, 1);
    expect(
      fixture.admin.requests.where((request) => request.$1 == 'POST').single.$2,
      'cron/jobs/review/trigger',
    );
  });
  testWidgets('history failure is never displayed as no runs', (tester) async {
    fixture.failRuns = true;
    final c = await controller();
    await show(
      tester,
      AdminScheduledTaskDetailPage(
        controller: c,
        initial: c.task('morning')!,
        onOpenSession: (_) async {},
      ),
    );
    await tester.scrollUntilVisible(
      find.text('Refresh runs'),
      350,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('task-detail-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('No recorded runs yet.'), findsNothing);
    expect(find.text('Refresh runs'), findsOneWidget);
  });
  testWidgets(
    'template creation uses typed values and local server destination',
    (tester) async {
      await show(tester, list());
      await tester.tap(find.text('New task'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start from a template'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Morning briefing').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, '09:00');
      await tester.tap(find.byTooltip('Create task'));
      await tester.pumpAndSettle();
      final request = fixture.admin.requests.firstWhere(
        (r) => r.$2 == 'cron/blueprints/instantiate',
      );
      expect(request.$4!['values'], {'time': '09:00', 'deliver': 'local'});
    },
  );
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'mixed history ${brightness.name} at $scale text opens only conversations',
        (tester) async {
          fixture.runRows.addAll([
            {
              'id': 'cron_output:morning:20260918_090000',
              'source': 'cron_output',
              'title': 'COMPLETED · Script-only run',
              'preview': 'The report was saved on the server.',
              'started_at': 1789700000,
            },
            {
              'id': 'cron_output:morning:exec:0',
              'source': 'cron_output',
              'title': 'FAILED · Script exited with code 1',
              'preview': 'Script exited with code 1',
              'started_at': 1789600000,
            },
            {
              'id': 'cron_output:morning:latest',
              'source': 'cron_output',
              'title': 'COMPLETED',
              'preview': null,
              'started_at': 1789500000,
            },
          ]);
          final opened = <ProfileSessionKey>[];
          final c = await controller();
          await show(
            tester,
            AdminScheduledTaskDetailPage(
              controller: c,
              initial: c.task('morning')!,
              onOpenSession: (key) async => opened.add(key),
            ),
            brightness: brightness,
            width: scale == 1 ? 390 : 320,
            scale: scale,
          );
          Future<void> reveal(String title) async {
            await tester.scrollUntilVisible(
              find.text(title),
              200,
              scrollable: find
                  .descendant(
                    of: find.byKey(const ValueKey('task-detail-scroll')),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            );
            await tester.ensureVisible(find.text(title));
            await tester.pumpAndSettle();
          }

          await reveal('COMPLETED · Script-only run');
          expect(
            find.text('The report was saved on the server.'),
            findsOneWidget,
          );
          await tester.tap(find.text('COMPLETED · Script-only run'));
          await tester.pumpAndSettle();
          expect(opened, isEmpty);
          await screenshot(tester, 'mixed-runs-${brightness.name}-$scale');
          for (final title in [
            'FAILED · Script exited with code 1',
            'COMPLETED',
          ]) {
            await reveal(title);
            await tester.tap(find.text(title));
            await tester.pumpAndSettle();
            expect(opened, isEmpty);
          }
          await tester.scrollUntilVisible(
            find.text('Your morning briefing'),
            -200,
            scrollable: find
                .descendant(
                  of: find.byKey(const ValueKey('task-detail-scroll')),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.ensureVisible(find.text('Your morning briefing'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Your morning briefing'));
          await tester.pumpAndSettle();
          expect(opened.single.workspace.profileName, 'personal');
          expect(opened.single.sessionId, 'cron_morning_123');
          expect(tester.takeException(), isNull);
        },
      );
    }
    for (final accent in WorkspaceAccent.values) {
      testWidgets('Studio list ${brightness.name} ${accent.name}', (
        tester,
      ) async {
        await show(tester, list(), brightness: brightness, accent: accent);
        expect(find.text('Morning briefing').hitTestable(), findsOneWidget);
        expect(find.byTooltip('Refresh tasks').hitTestable(), findsOneWidget);
        expect(tester.takeException(), null);
        await screenshot(tester, 'list-${brightness.name}-${accent.name}');
      });
    }
    testWidgets('detail and editor render ${brightness.name}', (tester) async {
      final c = await controller();
      await show(
        tester,
        AdminScheduledTaskDetailPage(
          controller: c,
          initial: c.task('morning')!,
          onOpenSession: (_) async {},
        ),
        brightness: brightness,
      );
      expect(tester.takeException(), null);
      await screenshot(tester, 'detail-${brightness.name}');
      await show(
        tester,
        AdminScheduledTaskEditorPage(controller: c),
        brightness: brightness,
      );
      expect(tester.takeException(), null);
      await screenshot(tester, 'editor-${brightness.name}');
    });
    testWidgets(
      '320 dp 200 percent ${brightness.name} list and keyboard editor',
      (tester) async {
        await show(
          tester,
          list(),
          brightness: brightness,
          width: 320,
          scale: 2,
        );
        expect(tester.takeException(), null);
        await screenshot(tester, 'large-list-${brightness.name}');
        final c = await controller();
        await show(
          tester,
          AdminScheduledTaskEditorPage(controller: c),
          brightness: brightness,
          width: 320,
          scale: 2,
          keyboard: 260,
        );
        expect(tester.takeException(), null);
        await screenshot(tester, 'large-editor-${brightness.name}');
        await tester.scrollUntilVisible(
          find.widgetWithText(TextFormField, 'Instructions'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(tester.takeException(), null);
      },
    );
  }
  testWidgets('empty and unavailable states are distinct', (tester) async {
    fixture.jobs.clear();
    await show(tester, list());
    expect(find.text('Make room for what’s next.'), findsOneWidget);
    fixture.failList = true;
    await tester.tap(find.byTooltip('Refresh tasks'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not reach the server'), findsOneWidget);
  });

  testWidgets(
    'required instructions are validated after scrolling off screen',
    (tester) async {
      final c = await controller();
      await show(tester, AdminScheduledTaskEditorPage(controller: c));
      await tester.scrollUntilVisible(
        find.text('Profile default'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byTooltip('Create task'));
      await tester.pumpAndSettle();
      expect(fixture.mutations, 0);
      expect(
        find.text('Add instructions for your agent.').hitTestable(),
        findsOneWidget,
      );
    },
  );

  testWidgets('editing past one-time task name leaves its instant unchanged', (
    tester,
  ) async {
    fixture.jobs['morning']!['schedule'] = {
      'kind': 'once',
      'run_at': '2025-11-02T01:30:00-04:00',
    };
    final c = await controller();
    await show(
      tester,
      AdminScheduledTaskEditorPage(controller: c, original: c.task('morning')),
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name (optional)'),
      'Renamed once',
    );
    await tester.tap(find.byTooltip('Save changes'));
    await tester.pumpAndSettle();
    final write = fixture.admin.requests.firstWhere((r) => r.$1 == 'PUT');
    expect(write.$4!['updates'], {'name': 'Renamed once'});
  });

  for (final example in [
    (label: 'expired', instant: '2025-11-02T01:30:00-04:00'),
    (label: 'far future', instant: '2046-10-03T09:45:00+08:00'),
  ]) {
    for (final cancelTime in [false, true]) {
      testWidgets(
        '${example.label} once picker cancellation preserves exact schedule at ${cancelTime ? 'time' : 'date'} step',
        (tester) async {
          fixture.jobs['morning']!['schedule'] = {
            'kind': 'once',
            'run_at': example.instant,
          };
          final c = await controller();
          await show(
            tester,
            AdminScheduledTaskEditorPage(
              controller: c,
              original: c.task('morning'),
              now: () => DateTime(2026, 10, 3, 12),
            ),
          );
          // The date is localized, while the trailing timezone label is stable.
          final dateButton = find.ancestor(
            of: find.textContaining(' · Phone time'),
            matching: find.byType(OutlinedButton),
          );
          await tester.ensureVisible(dateButton);
          await tester.tap(dateButton);
          await tester.pumpAndSettle();
          expect(tester.takeException(), null);
          final dialog = tester.widget<DatePickerDialog>(
            find.byType(DatePickerDialog),
          );
          expect(
            dialog.initialDate,
            example.label == 'expired' ? DateTime(2026, 10, 3) : DateTime(2036),
          );
          expect(dialog.firstDate, DateTime(2026, 10, 3));
          expect(dialog.lastDate, DateTime(2036));
          if (cancelTime) {
            await tester.tap(find.text('OK'));
            await tester.pumpAndSettle();
            expect(find.byType(TimePickerDialog), findsOneWidget);
          }
          await tester.tap(
            find.descendant(
              of: find.byType(cancelTime ? TimePickerDialog : DatePickerDialog),
              matching: find.text('Cancel'),
            ),
          );
          await tester.pumpAndSettle();
          expect(fixture.mutations, 0);
          expect(
            fixture.jobs['morning']!['schedule']['run_at'],
            example.instant,
          );
          expect(
            tester
                .widget<PopScope>(
                  find.descendant(
                    of: find.byType(AdminScheduledTaskEditorPage),
                    matching: find.byWidgetPredicate(
                      (widget) => widget is PopScope,
                    ),
                  ),
                )
                .canPop,
            true,
          );
          await tester.scrollUntilVisible(
            find.widgetWithText(TextFormField, 'Name (optional)'),
            -250,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.enterText(
            find.widgetWithText(TextFormField, 'Name (optional)'),
            'After cancel',
          );
          await tester.tap(find.byTooltip('Save changes'));
          await tester.pumpAndSettle();
          final write = fixture.admin.requests.singleWhere(
            (request) => request.$1 == 'PUT',
          );
          expect(write.$4!['updates'], {'name': 'After cancel'});
          expect(
            fixture.jobs['morning']!['schedule']['run_at'],
            example.instant,
          );
          expect(tester.takeException(), null);
        },
      );
    }
    testWidgets(
      '${example.label} once picker commits only explicit date and time selection',
      (tester) async {
        fixture.jobs['morning']!['schedule'] = {
          'kind': 'once',
          'run_at': example.instant,
        };
        final c = await controller();
        await show(
          tester,
          AdminScheduledTaskEditorPage(
            controller: c,
            original: c.task('morning'),
            now: () => DateTime(2026, 10, 3, 12),
          ),
        );
        final dateButton = find.ancestor(
          of: find.textContaining(' · Phone time'),
          matching: find.byType(OutlinedButton),
        );
        await tester.ensureVisible(dateButton);
        await tester.tap(dateButton);
        await tester.pumpAndSettle();
        expect(tester.takeException(), null);
        if (example.label == 'expired') {
          await tester.tap(find.text('4').hitTestable());
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        final time = tester
            .widget<TimePickerDialog>(find.byType(TimePickerDialog))
            .initialTime;
        final selected = example.label == 'expired'
            ? DateTime(2026, 10, 4)
            : DateTime(2036);
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(fixture.mutations, 0);
        await tester.tap(find.byTooltip('Save changes'));
        await tester.pumpAndSettle();
        final write = fixture.admin.requests.singleWhere(
          (request) => request.$1 == 'PUT',
        );
        expect(write.$4!['updates'], {
          'schedule': DateTime(
            selected.year,
            selected.month,
            selected.day,
            time.hour,
            time.minute,
          ).toUtc().toIso8601String(),
        });
        final observed = c.task('morning')!;
        expect(observed.schedule['kind'], 'once');
        expect(
          DateTime.parse(observed.schedule['run_at'] as String),
          DateTime(
            selected.year,
            selected.month,
            selected.day,
            time.hour,
            time.minute,
          ).toUtc(),
        );
        expect(tester.takeException(), null);
      },
    );
  }

  testWidgets('pushed narrow task titles grow with large text', (tester) async {
    await show(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => list())),
            child: const Text('Open tasks'),
          ),
        ),
      ),
      width: 320,
      scale: 2,
    );
    await tester.tap(find.text('Open tasks'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), null);
    expect(find.text('Scheduled tasks').hitTestable(), findsOneWidget);
    expect(find.byTooltip('Refresh tasks').hitTestable(), findsOneWidget);
    expect(find.byTooltip('Back').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Open tasks'), findsOneWidget);
  });
}
