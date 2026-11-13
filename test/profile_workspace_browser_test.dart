import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/connection_access.dart';
import 'support/chat_browser_interactions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/screens/profile_workspace_browser.dart';
import 'package:wing/core/services/composer_draft_store.dart';
import 'package:wing/core/widgets/context_ring.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/theme/project_icon_glyphs.dart';
import 'support/profile_browser_fixture.dart';
import 'support/browser_mutations_fixture.dart';

void main() {
  const capture = bool.fromEnvironment('CAPTURE_CHAT_PROJECT');
  const captureKey = ValueKey('chat-project-capture');
  setUpAll(() async {
    if (!capture) return;
    const fontDirectory = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final font in {
      'Roboto': '$fontDirectory/Roboto-Regular.ttf',
      'MaterialIcons': '$fontDirectory/MaterialIcons-Regular.otf',
      'WingIcons': 'assets/fonts/wing-icons.ttf',
      'WingProjectIcons': 'assets/fonts/codicons.ttf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            Future.value(
              ByteData.sublistView(await File(font.value).readAsBytes()),
            ),
          ))
          .load();
    }
  });
  late _ProjectFilterFixture fixture;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    fixture = _ProjectFilterFixture();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'host',
          label: 'Prestige',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'settings',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: fixture.gateway,
    );
    await controller.initialize();
  });
  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });
  Future<void> show(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(460, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.light),
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
  }

  Future<void> settleWorkspaceRefresh(WidgetTester tester) async {
    for (
      var attempt = 0;
      attempt < 100 && controller.refreshingWorkspace;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(controller.refreshingWorkspace, isFalse);
    await tester.pumpAndSettle();
  }

  Future<BrowserMutationsFixture> useMutationHost() async {
    controller.dispose();
    appPreferences.dispose();
    final host = BrowserMutationsFixture();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'host',
          label: 'Prestige',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'production-browser-actions',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
    return host;
  }

  Future<void> showActions(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) async {
    await tester.binding.setSurfaceSize(Size(scale == 1 ? 390 : 320, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: wingTheme(brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: true,
              textScaler: TextScaler.linear(scale),
            ),
            child: child!,
          ),
          home: ProfileWorkspaceScreen(
            controller: controller,
            createBotsSession: () => BotsSession((_) async => const []),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-profile-work')));
    await tester.pumpAndSettle();
  }

  Future<void> actionCapture(WidgetTester tester, String name) async {
    if (!capture) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(captureKey),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final target = File(
          'build/design-previews/browser-lifetime/site/renders/$name.png',
        );
        target.parent.createSync(recursive: true);
        target.writeAsBytesSync(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  Future<void> openWorkActions(WidgetTester tester) async {
    final row = find.byKey(const ValueKey('chat-work-newest'));
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('chat-list-false')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: row, matching: find.byTooltip('Chat actions')),
    );
    await tester.pumpAndSettle();
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('cross-profile chat actions retain the workspace browser '
          '${brightness.name} $scale', (tester) async {
        final host = await useMutationHost();
        final work = controller.browserResource('work').scope;
        final retained = await controller.openSession(
          ProfileSessionKey(work, 'newest'),
        );
        expect(retained, isNotNull);
        await controller.updateDraft(retained!, 'Keep this work draft');
        await controller.switchProfile('personal', resetNavigation: true);
        host.updates.clear();
        await showActions(tester, brightness: brightness, scale: scale);
        final browser = tester.state(find.byType(ProfileWorkspaceBrowser));
        await tester.enterText(
          find.byKey(const ValueKey('workspace-search')),
          'work',
        );
        await tester.pumpAndSettle();
        await openWorkActions(tester);
        expect(controller.current!.scope, work);
        expect(controller.current!.chat, isNull);
        expect(
          tester.state(find.byType(ProfileWorkspaceBrowser)),
          same(browser),
        );
        expect(find.byKey(const ValueKey('action-pin')), findsOneWidget);
        await actionCapture(tester, 'chat-menu-${brightness.name}-$scale');
        await tester.tap(find.byKey(const ValueKey('action-pin')));
        await tester.pumpAndSettle();
        expect(
          host.updates.where((update) => update.$1 == 'work'),
          hasLength(1),
        );
        expect(
          host.updates.where((update) => update.$1 == 'personal'),
          isEmpty,
        );
        expect(retained.composer.observation.text, 'Keep this work draft');
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('workspace-search')))
              .controller!
              .text,
          'work',
        );
        expect(
          tester.state(find.byType(ProfileWorkspaceBrowser)),
          same(browser),
        );
        expect(
          find.byKey(const ValueKey('chat-personal-newest')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets(
    'a superseded production chat menu cannot mutate its old profile',
    (tester) async {
      final host = await useMutationHost();
      await showActions(tester);
      await openWorkActions(tester);
      await controller.switchProfile('personal', resetNavigation: true);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('action-pin')));
      await tester.pumpAndSettle();
      expect(host.updates, isEmpty);
      expect(
        find.text('Profile changed. Open the menu again.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'cross-profile project rename uses its captured production menu',
    (tester) async {
      final host = await useMutationHost();
      await showActions(tester);
      final project = find.byKey(const ValueKey('project-work-work-project'));
      await tester.ensureVisible(project);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: project,
          matching: find.byTooltip('Project actions'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('project-action-editProject')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('project-name-field')),
        'Renamed work project',
      );
      await tester.tap(find.byKey(const ValueKey('project-edit-confirm')));
      await tester.pumpAndSettle();
      expect(
        host.projectChanges['work/work-project']?['label'],
        'Renamed work project',
      );
      expect(host.projectChanges.keys, ['work/work-project']);
      expect(find.text('Renamed work project'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('cross-profile saved draft can be discarded from the workspace', (
    tester,
  ) async {
    final host = await useMutationHost();
    final drafts = ComposerDraftStore(
      controller.preferences,
      connectionIdentity: controller.connectionIdentity,
    );
    await drafts.write(
      profileName: 'work',
      sessionId: 'missing-work-draft',
      text: 'Saved work draft',
      attachments: const [],
    );
    await drafts.write(
      profileName: 'personal',
      sessionId: 'missing-personal-draft',
      text: 'Saved personal draft',
      attachments: const [],
    );
    await showActions(tester);
    expect(controller.current!.scope.profileName, 'personal');
    final draft = find.byKey(const ValueKey('saved-draft-missing-work-draft'));
    expect(draft, findsOneWidget);
    expect(
      find.byKey(const ValueKey('saved-draft-missing-personal-draft')),
      findsNothing,
    );
    await tester.ensureVisible(draft);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: draft, matching: find.byTooltip('Draft actions')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('action-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Discard draft'));
    await tester.pumpAndSettle();
    expect(
      await drafts.read(profileName: 'work', sessionId: 'missing-work-draft'),
      isNull,
    );
    expect(
      (await drafts.read(
        profileName: 'personal',
        sessionId: 'missing-personal-draft',
      ))?.text,
      'Saved personal draft',
    );
    expect(host.deletes, isEmpty);
    expect(host.updates, isEmpty);
    expect(
      find.byKey(const ValueKey('saved-draft-missing-work-draft')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  Future<void> openNewProject(WidgetTester tester) async {
    await tester.longPress(find.byKey(const ValueKey('workspace-new-chat')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-new-project')));
    await tester.pumpAndSettle();
  }

  String folderLocation(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const ValueKey('project-folder-field')))
      .controller!
      .text;

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'New project suggests profile kebab-case location ${brightness.name} $scale',
        (tester) async {
          final host = await useMutationHost();
          await showActions(tester, brightness: brightness, scale: scale);
          await openNewProject(tester);
          expect(host.defaultFolderProfiles, ['work']);
          expect(folderLocation(tester), '/work');
          for (final entry in {
            'Initial Project': '/work/initial-project',
            '  My__APIProject / 2026!  ': '/work/my-api-project-2026',
            'Projet Été': '/work/projet-été',
            '': '/work',
            'My New Project': '/work/my-new-project',
          }.entries) {
            await tester.enterText(
              find.byKey(const ValueKey('project-name-field')),
              entry.key,
            );
            expect(folderLocation(tester), entry.value);
          }
          await tester.pumpAndSettle();
          await actionCapture(
            tester,
            'project-default-normal-${brightness.name}-$scale',
          );
          tester.view.viewInsets = FakeViewPadding(
            bottom: 260 * tester.view.devicePixelRatio,
          );
          addTearDown(tester.view.resetViewInsets);
          await tester.pumpAndSettle();
          final create = find.byKey(const ValueKey('project-create-confirm'));
          expect(create.hitTestable(), findsOneWidget);
          await tester.ensureVisible(
            find.byKey(const ValueKey('project-folder-field')),
          );
          await actionCapture(
            tester,
            'project-default-${brightness.name}-$scale',
          );
          await tester.tap(create);
          await tester.pumpAndSettle();
          expect(host.folderCreates.single.$2['path'], '/work/my-new-project');
          expect(
            host.projectChanges['work/created']?['path'],
            '/work/my-new-project',
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets(
    'manual location wins over delayed default and later name edits',
    (tester) async {
      final host = await useMutationHost();
      host.defaultFolderGate = Completer<void>();
      addTearDown(() {
        if (!host.defaultFolderGate!.isCompleted) {
          host.defaultFolderGate!.complete();
        }
      });
      await showActions(tester);
      await openNewProject(tester);
      expect(find.text('New project'), findsWidgets);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await actionCapture(tester, 'project-default-pending');
      await tester.enterText(
        find.byKey(const ValueKey('project-name-field')),
        'Typed before load',
      );
      await tester.enterText(
        find.byKey(const ValueKey('project-folder-field')),
        '/custom/location',
      );
      host.defaultFolderGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(folderLocation(tester), '/custom/location');
      await tester.enterText(
        find.byKey(const ValueKey('project-name-field')),
        'Changed after load',
      );
      expect(folderLocation(tester), '/custom/location');
      await tester.tap(find.byKey(const ValueKey('project-create-confirm')));
      await tester.pumpAndSettle();
      expect(host.folderCreates.single.$2['path'], '/custom/location');
      expect(
        host.projectChanges['work/created']?['label'],
        'Changed after load',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'default failure retries using the latest name and cancel retires a read',
    (tester) async {
      final host = await useMutationHost();
      host.defaultFolderGate = Completer<void>();
      addTearDown(() {
        if (!host.defaultFolderGate!.isCompleted) {
          host.defaultFolderGate!.complete();
        }
      });
      host.failDefaultFolder = true;
      await showActions(tester);
      await openNewProject(tester);
      await tester.enterText(
        find.byKey(const ValueKey('project-name-field')),
        'Name before default',
      );
      host.defaultFolderGate!.complete();
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Could not load the profile folder'),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await actionCapture(tester, 'project-default-failed');
      host.failDefaultFolder = false;
      host.defaultFolderGate = Completer<void>();
      await tester.ensureVisible(find.byTooltip('Retry profile folder'));
      await tester.tap(find.byTooltip('Retry profile folder'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('project-name-field')),
        'Latest Project',
      );
      host.defaultFolderGate!.complete();
      await tester.pumpAndSettle();
      expect(folderLocation(tester), '/work/latest-project');
      expect(
        find.textContaining('Could not load the profile folder'),
        findsNothing,
      );
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
      host.defaultFolderGate = Completer<void>();
      await openNewProject(tester);
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
      host.defaultFolderGate!.complete();
      await tester.pumpAndSettle();
      expect(host.folderCreates, isEmpty);
      expect(host.projectChanges, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('profile change rejects a late default directory', (
    tester,
  ) async {
    final host = await useMutationHost();
    host.defaultFolderGate = Completer<void>();
    addTearDown(() {
      if (!host.defaultFolderGate!.isCompleted) {
        host.defaultFolderGate!.complete();
      }
    });
    await showActions(tester);
    await openNewProject(tester);
    await tester.enterText(
      find.byKey(const ValueKey('project-name-field')),
      'Captured work',
    );
    await controller.switchProfile('personal');
    host.defaultFolderGate!.complete();
    await tester.pumpAndSettle();
    expect(folderLocation(tester), isEmpty);
    expect(host.defaultFolderProfiles, ['work']);
    expect(
      find.textContaining('Could not load the profile folder'),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('project-folder-field')),
      '/manual/path',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('project-create-confirm')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Profile changed.'), findsOneWidget);
    expect(host.folderCreates, isEmpty);
    expect(host.projectChanges, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'New project FAB keeps its captured profile and chosen appearance',
    (tester) async {
      final host = await useMutationHost();
      await showActions(tester);
      final browser = tester.state(find.byType(ProfileWorkspaceBrowser));
      await tester.longPress(find.byKey(const ValueKey('workspace-new-chat')));
      await tester.pumpAndSettle();
      final chatRect = tester.getRect(
        find.byKey(const ValueKey('workspace-new-chat')),
      );
      final projectRect = tester.getRect(
        find.byKey(const ValueKey('workspace-new-project')),
      );
      expect(projectRect.bottom, lessThan(chatRect.top));
      expect(
        find.byKey(const ValueKey('workspace-new-project')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('workspace-new-project')));
      await tester.pumpAndSettle();
      expect(controller.current!.scope.profileName, 'work');
      expect(tester.state(find.byType(ProfileWorkspaceBrowser)), same(browser));
      expect(find.text('New project'), findsWidgets);
      await tester.enterText(
        find.byKey(const ValueKey('project-name-field')),
        'Created work project',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('project-color-7')));
      await tester.tap(find.byKey(const ValueKey('project-color-7')));
      await tester.ensureVisible(
        find.byKey(const ValueKey('project-choose-icon')),
      );
      await tester.tap(find.byKey(const ValueKey('project-choose-icon')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('project-icon-rocket')),
      );
      await tester.tap(find.byKey(const ValueKey('project-icon-rocket')));
      await tester.tap(find.byKey(const ValueKey('project-icon-confirm')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('project-choose-folder')),
      );
      await tester.tap(find.byKey(const ValueKey('project-choose-folder')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('project-folder-/work/new')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('project-folder-continue')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('project-name-field')),
        'Another name',
      );
      expect(folderLocation(tester), '/work/new');
      await tester.enterText(
        find.byKey(const ValueKey('project-name-field')),
        'Created work project',
      );
      await tester.tap(find.byKey(const ValueKey('project-create-confirm')));
      await tester.pumpAndSettle();
      expect(host.projectChanges['work/created']?['color'], 'hsl(210 68% 58%)');
      expect(host.projectChanges['work/created']?['icon'], 'rocket');
      expect(
        host.projectChanges['work/created']?['label'],
        'Created work project',
      );
      expect(host.projectChanges['work/created']?['path'], '/work/new');
      expect(host.projectChanges.keys, ['work/created']);
      expect(find.text('Created work project'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final failedStep in ['folder', 'details']) {
        testWidgets(
          'Edit project feedback ${brightness.name} $scale failure=$failedStep',
          (tester) async {
            final semantics = tester.ensureSemantics();
            try {
              final host = await useMutationHost();
              final folderGate = Completer<void>();
              final detailsGate = Completer<void>();
              host.rpcDelays['projects.add_folder'] = folderGate;
              host.rpcDelays['projects.update'] = detailsGate;
              host.failPrimaryFolder = failedStep == 'folder';
              host.failProjectUpdate = failedStep == 'details';
              addTearDown(() {
                if (!folderGate.isCompleted) folderGate.complete();
                if (!detailsGate.isCompleted) detailsGate.complete();
                tester.view.resetViewInsets();
              });
              await showActions(tester, brightness: brightness, scale: scale);
              final project = find.byKey(
                const ValueKey('project-work-work-project'),
              );
              await tester.ensureVisible(project);
              await tester.tap(
                find.descendant(
                  of: project,
                  matching: find.byTooltip('Project actions'),
                ),
              );
              await tester.pumpAndSettle();
              expect(
                find.byKey(const ValueKey('project-action-rename')),
                findsNothing,
              );
              expect(
                find.byKey(const ValueKey('project-action-appearance')),
                findsNothing,
              );
              await actionCapture(
                tester,
                'project-edit-menu-${brightness.name}-$scale',
              );
              await tester.tap(
                find.byKey(const ValueKey('project-action-editProject')),
              );
              await tester.pumpAndSettle();
              final name = find.byKey(const ValueKey('project-name-field'));
              expect(
                tester.widget<TextField>(name).controller!.text,
                'Work project',
              );
              expect(find.byTooltip('Change project folder'), findsOneWidget);
              await actionCapture(
                tester,
                'project-edit-form-${brightness.name}-$scale',
              );
              await tester.enterText(name, 'Edited work project');
              tester.view.viewInsets = FakeViewPadding(
                bottom: 260 * tester.view.devicePixelRatio,
              );
              await tester.pumpAndSettle();
              final save = find.byKey(const ValueKey('project-edit-confirm'));
              expect(save.hitTestable(), findsOneWidget);
              expect(tester.getRect(save).bottom, lessThanOrEqualTo(844 - 260));
              await actionCapture(
                tester,
                'project-edit-keyboard-${brightness.name}-$scale',
              );
              tester.view.resetViewInsets();
              await tester.pumpAndSettle();
              await tester.ensureVisible(
                find.byKey(const ValueKey('project-color-7')),
              );
              await tester.tap(find.byKey(const ValueKey('project-color-7')));
              await tester.ensureVisible(
                find.byKey(const ValueKey('project-choose-icon')),
              );
              await tester.tap(
                find.byKey(const ValueKey('project-choose-icon')),
              );
              await tester.pumpAndSettle();
              await tester.enterText(
                find.byKey(const ValueKey('project-icon-search-field')),
                'rocket',
              );
              await tester.pumpAndSettle();
              await tester.ensureVisible(
                find.byKey(const ValueKey('project-icon-rocket')),
              );
              await tester.tap(
                find.byKey(const ValueKey('project-icon-rocket')),
              );
              await tester.tap(
                find.byKey(const ValueKey('project-icon-confirm')),
              );
              await tester.pumpAndSettle();
              await tester.ensureVisible(
                find.byTooltip('Change project folder'),
              );
              await tester.tap(find.byTooltip('Change project folder'));
              await tester.pumpAndSettle();
              expect(
                tester
                    .widget<Text>(
                      find.byKey(const ValueKey('project-folder-location')),
                    )
                    .data,
                '/work',
              );
              await tester.tap(
                find.byKey(const ValueKey('project-folder-/work/new')),
              );
              await tester.pumpAndSettle();
              await tester.tap(
                find.byKey(const ValueKey('project-folder-continue')),
              );
              await tester.pumpAndSettle();
              await tester.tap(save);
              await tester.pumpAndSettle();
              expect(find.bySemanticsLabel('Saving project'), findsOneWidget);
              expect(tester.widget<IconButton>(save).onPressed, isNull);
              expect(tester.widget<TextField>(name).enabled, isFalse);
              await tester.tap(save, warnIfMissed: false);
              await tester.tapAt(const Offset(8, 8));
              await tester.binding.handlePopRoute();
              await tester.pump();
              expect(find.text('Edit project'), findsOneWidget);
              expect(
                host.wireCalls.where((m) => m == 'projects.add_folder'),
                hasLength(1),
              );
              expect(
                host.wireCalls.where((m) => m == 'projects.update'),
                isEmpty,
              );
              final footer = tester.getRect(save);
              await actionCapture(
                tester,
                'project-edit-saving-folder-${brightness.name}-$scale',
              );
              folderGate.complete();
              await tester.pumpAndSettle();
              if (failedStep == 'details') {
                expect(find.bySemanticsLabel('Saving project'), findsOneWidget);
                expect(tester.getRect(save), footer);
                expect(
                  controller.current!.projects.single['path'],
                  '/work/new',
                );
                expect(
                  controller.current!.projects.single['name'],
                  'Work project',
                );
                await actionCapture(
                  tester,
                  'project-edit-saving-details-${brightness.name}-$scale',
                );
                detailsGate.complete();
                await tester.pumpAndSettle();
                expect(find.textContaining('Folder saved.'), findsOneWidget);
              } else {
                expect(
                  host.wireCalls.where((m) => m == 'projects.update'),
                  isEmpty,
                );
                expect(controller.current!.projects.single['path'], '/work');
                detailsGate.complete();
              }
              expect(find.bySemanticsLabel('Saving project'), findsNothing);
              expect(
                tester.widget<TextField>(name).controller!.text,
                'Edited work project',
              );
              expect(
                tester
                    .widget<Text>(
                      find.byKey(const ValueKey('project-chosen-folder')),
                    )
                    .data,
                '/work/new',
              );
              expect(save.hitTestable(), findsOneWidget);
              await actionCapture(
                tester,
                'project-edit-error-${brightness.name}-$scale-$failedStep',
              );
              host.failPrimaryFolder = false;
              host.failProjectUpdate = false;
              await tester.tap(save);
              await tester.pumpAndSettle();
              expect(find.text('Edit project'), findsNothing);
              expect(
                controller.current!.projects.single['name'],
                'Edited work project',
              );
              expect(
                controller.current!.projects.single['color'],
                'hsl(210 68% 58%)',
              );
              expect(controller.current!.projects.single['icon'], 'rocket');
              expect(
                (controller.current!.projects.single['folders'] as List).map(
                  (f) => f['path'],
                ),
                ['/work/new'],
              );
              expect(
                host.wireCalls.where((m) => m == 'projects.add_folder'),
                hasLength(failedStep == 'folder' ? 2 : 1),
              );
              expect(
                host.wireCalls.where((m) => m == 'projects.remove_folder'),
                hasLength(1),
              );
              expect(host.folderCreates, isEmpty);
              expect(tester.takeException(), isNull);
              await tester.pumpWidget(const SizedBox.shrink());
            } finally {
              semantics.dispose();
            }
          },
        );
      }
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final failFolder in [false, true]) {
        testWidgets(
          'New project folder creation feedback ${brightness.name} $scale failure=$failFolder',
          (tester) async {
            final semantics = tester.ensureSemantics();
            try {
              final host = await useMutationHost();
              host.folderCreateGate = Completer<void>();
              host.failFolderCreate = failFolder;
              host.rpcDelays['projects.create'] = Completer<void>();
              addTearDown(() {
                if (!host.folderCreateGate!.isCompleted) {
                  host.folderCreateGate!.complete();
                }
                if (!host.rpcDelays['projects.create']!.isCompleted) {
                  host.rpcDelays['projects.create']!.complete();
                }
                tester.view.resetViewInsets();
              });
              await showActions(tester, brightness: brightness, scale: scale);
              await tester.tap(find.byTooltip('Chat list options'));
              await tester.pumpAndSettle();
              final choice = find.byKey(
                const ValueKey('chat-menu-new-project'),
              );
              await tester.scrollUntilVisible(
                choice,
                120,
                scrollable: find.byType(Scrollable).last,
              );
              await tester.ensureVisible(choice);
              await tester.tap(choice);
              await tester.pumpAndSettle();
              await tester.enterText(
                find.byKey(const ValueKey('project-name-field')),
                'Bangkok Oct26',
              );
              tester.view.viewInsets = FakeViewPadding(
                bottom: 260 * tester.view.devicePixelRatio,
              );
              await tester.pumpAndSettle();
              final create = find.byKey(
                const ValueKey('project-create-confirm'),
              );
              expect(create.hitTestable(), findsOneWidget);
              expect(
                tester.getRect(create).bottom,
                lessThanOrEqualTo(844 - 260),
              );
              await actionCapture(
                tester,
                'project-keyboard-${brightness.name}-$scale',
              );
              tester.view.resetViewInsets();
              await tester.pumpAndSettle();
              await tester.tap(
                find.byKey(const ValueKey('project-choose-folder')),
              );
              await tester.pumpAndSettle();
              await actionCapture(
                tester,
                'folder-browser-${brightness.name}-$scale',
              );
              await tester.tap(find.byTooltip('New folder'));
              await tester.pumpAndSettle();
              await tester.enterText(
                find.byKey(const ValueKey('project-new-folder-name')),
                'New trip',
              );
              tester.view.viewInsets = FakeViewPadding(
                bottom: 260 * tester.view.devicePixelRatio,
              );
              await tester.pumpAndSettle();
              expect(
                find
                    .byKey(const ValueKey('project-new-folder-create'))
                    .hitTestable(),
                findsOneWidget,
              );
              await actionCapture(
                tester,
                'folder-browser-keyboard-${brightness.name}-$scale',
              );
              tester.view.resetViewInsets();
              await tester.pumpAndSettle();
              await tester.tap(find.byTooltip('Close new folder'));
              await tester.pumpAndSettle();
              await tester.tap(
                find.byKey(
                  const ValueKey('project-folder-/work/bangkok-oct26'),
                ),
              );
              await tester.pumpAndSettle();
              await tester.tap(
                find.byKey(const ValueKey('project-folder-continue')),
              );
              await tester.pumpAndSettle();
              await actionCapture(
                tester,
                'project-form-${brightness.name}-$scale',
              );
              await tester.tap(
                find.byKey(const ValueKey('project-create-confirm')),
              );
              await tester.pumpAndSettle();
              expect(find.bySemanticsLabel('Creating project'), findsOneWidget);
              expect(host.folderCreates.single.$1, 'files/mkdir?profile=work');
              expect(host.projectChanges, isEmpty);
              expect(find.bySemanticsLabel('Creating project'), findsOneWidget);
              final row = find.byKey(const ValueKey('chat-work-newest'));
              final before = tester.getRect(row);
              final search = find.byKey(const ValueKey('workspace-search'));
              expect(tester.widget<TextField>(search).enabled, isNot(false));
              await actionCapture(
                tester,
                'project-folder-${brightness.name}-$scale-$failFolder',
              );
              host.folderCreateGate!.complete();
              await tester.pumpAndSettle();
              if (!failFolder) {
                expect(host.wireCalls, contains('projects.create'));
                expect(host.projectChanges, isEmpty);
                expect(
                  find.bySemanticsLabel('Creating project'),
                  findsOneWidget,
                );
                expect(tester.getRect(row), before);
                host.rpcDelays['projects.create']!.complete();
                await tester.pumpAndSettle();
                expect(
                  host.projectChanges['work/created']?['path'],
                  '/work/bangkok-oct26',
                );
              } else {
                expect(host.wireCalls, isNot(contains('projects.create')));
                expect(
                  find.textContaining('Could not create the project folder'),
                  findsOneWidget,
                );
                expect(
                  find
                      .descendant(
                        of: find.byType(AlertDialog),
                        matching: find.byIcon(Icons.error_outline),
                      )
                      .hitTestable(),
                  findsOneWidget,
                );
                await actionCapture(
                  tester,
                  'project-error-${brightness.name}-$scale',
                );
                if (scale == 2) {
                  await tester.drag(
                    find.byKey(const ValueKey('project-save-error')),
                    const Offset(0, -240),
                  );
                  await tester.pumpAndSettle();
                  expect(
                    find
                        .byKey(const ValueKey('project-create-confirm'))
                        .hitTestable(),
                    findsOneWidget,
                  );
                  await actionCapture(
                    tester,
                    'project-error-details-${brightness.name}-$scale',
                  );
                }
              }
              expect(find.bySemanticsLabel('Creating project'), findsNothing);
              if (failFolder) {
                expect(
                  tester
                      .widget<TextField>(
                        find.byKey(const ValueKey('project-name-field')),
                      )
                      .controller!
                      .text,
                  'Bangkok Oct26',
                );
                expect(find.text('/work/bangkok-oct26'), findsOneWidget);
                await tester.tap(find.byTooltip('Cancel'));
                await tester.pumpAndSettle();
              }
              expect(tester.getRect(row), before);
              expect(tester.takeException(), isNull);
              await tester.pumpWidget(const SizedBox.shrink());
            } finally {
              semantics.dispose();
            }
          },
        );
      }
    }
  }

  for (final failAfterResume in [false, true]) {
    testWidgets('background chat read is retired when its failure arrives '
        '${failAfterResume ? 'after' : 'before'} resume', (tester) async {
      final held = Completer<void>();
      fixture.heldListRead = held;
      addTearDown(() {
        if (!held.isCompleted) held.complete();
        if (tester.binding.lifecycleState == AppLifecycleState.paused) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
        }
        if (tester.binding.lifecycleState == AppLifecycleState.hidden) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
        }
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      });
      await show(tester);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      await tester.pump();
      expect(fixture.heldListEntered, isTrue);
      expect(
        find.byKey(const ValueKey('chat-personal-newest')),
        findsOneWidget,
      );
      final readsBeforePause = fixture.workListReads;
      fixture.backgroundBlocked = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      if (!failAfterResume) {
        held.completeError(const SocketException('Background access blocked'));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
        expect(fixture.workListReads, readsBeforePause);
      }
      fixture.backgroundBlocked = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Could not finish loading'), findsNothing);
      expect(fixture.workListReads, greaterThan(readsBeforePause));
      if (failAfterResume) {
        held.completeError(const SocketException('Retired background failure'));
      }
      // Workspace recovery also persists its snapshot outside fake async.
      for (var attempt = 0; attempt < 80; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        if (!controller.recovering &&
            find
                .byKey(const ValueKey('chat-work-newest'))
                .evaluate()
                .isNotEmpty) {
          break;
        }
      }
      expect(find.textContaining('Could not finish loading'), findsNothing);
      expect(find.byKey(const ValueKey('chat-work-newest')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('chat-personal-newest')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('New chat replaces the browser while profile reads are held', (
    tester,
  ) async {
    final gate = Completer<void>();
    fixture.pageDelays[('work', 0)] = gate;
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    await show(tester);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chat-profile-work')));
    await tester.pump();
    final connectionGate = Completer<void>();
    fixture.connectDelay = connectionGate;
    addTearDown(() {
      if (!connectionGate.isCompleted) connectionGate.complete();
    });
    await tester.tap(find.byKey(const ValueKey('workspace-new-chat')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    connectionGate.complete();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(gate.isCompleted, isFalse);
    expect(find.byKey(const ValueKey('conversation-composer')), findsOneWidget);
    expect(controller.current?.chat?.key.workspace.profileName, 'work');
    expect(find.byKey(const ValueKey('workspace-new-chat')), findsNothing);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('conversation-composer')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final sameProfile in [true, false]) {
    testWidgets(
      sameProfile
          ? 'saved chat opens before same-profile refresh completes'
          : 'saved chat opens before profile loading completes',
      (tester) async {
        fixture.recoveryHistory = [
          {'id': 1, 'role': 'assistant', 'content': 'Selected saved answer'},
        ];
        await show(tester);
        await tester.pumpAndSettle();
        final profile = sameProfile ? 'personal' : 'work';
        final gate = Completer<void>();
        fixture.pageDelays[(profile, 0)] = gate;
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        Future<void>? refreshing;
        if (sameProfile) {
          refreshing = controller.refresh();
        } else {
          await tester.tap(find.byKey(const ValueKey('chat-profile-work')));
        }
        await tester.pump();
        await tester.tap(find.byKey(ValueKey('chat-$profile-newest')));
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const ValueKey('chat-filter-profile')), findsNothing);
        for (
          var attempt = 0;
          attempt < 80 &&
              (controller.notificationChat != null ||
                  find
                      .textContaining(
                        'Selected saved answer',
                        findRichText: true,
                      )
                      .evaluate()
                      .isEmpty);
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(gate.isCompleted, isFalse);
        expect(controller.notificationChat, isNull);
        expect(controller.current?.chat?.key.workspace.profileName, profile);
        expect(controller.current?.chat?.key.sessionId, 'newest');
        expect(
          controller.current?.chat?.title,
          sameProfile ? 'Improve the conversation list' : 'Work chat',
        );
        expect(
          find.textContaining('Selected saved answer', findRichText: true),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('conversation-composer')),
          findsOneWidget,
        );
        final resumeCalls = fixture.calls
            .where((call) => call.$2 == 'session.resume')
            .length;
        expect(resumeCalls, 1);
        gate.complete();
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump();
        if (refreshing != null) await refreshing;
        expect(controller.current?.chat?.key.workspace.profileName, profile);
        expect(controller.current?.chat?.key.sessionId, 'newest');
        expect(
          find.textContaining('Selected saved answer', findRichText: true),
          findsOneWidget,
        );
        expect(
          fixture.calls.where((call) => call.$2 == 'prompt.submit'),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final leaveChat in [false, true]) {
    testWidgets(
      leaveChat
          ? 'Back cancels recovery after the chat browser is replaced'
          : 'saved chat recovery survives replacing the chat browser',
      (tester) async {
        fixture.recoveryHistory = [
          {'id': 1, 'role': 'assistant', 'content': 'Saved recovery answer'},
        ];
        await show(tester);
        await tester.pumpAndSettle();
        fixture.connectUnavailable = true;
        await controller.reconnect(controller.current!.scope);
        fixture.connectUnavailable = false;
        fixture.connectDelay = Completer<void>();
        addTearDown(() {
          if (!fixture.connectDelay!.isCompleted) {
            fixture.connectDelay!.complete();
          }
        });
        expect(controller.recovering, isTrue);

        final row = find.byKey(const ValueKey('chat-personal-newest'));
        await tester.ensureVisible(row);
        await tester.tap(row);
        await tester.pump();
        await tester.pump();
        expect(controller.notificationChat, isNotNull);
        await controller.updateDraft(
          controller.notificationChat!,
          'Keep this unsent draft',
        );
        expect(find.byKey(const ValueKey('chat-filter-profile')), findsNothing);
        expect(find.text('Reconnecting to Prestige'), findsNothing);
        expect(find.byType(StudioLoading), findsOneWidget);
        expect(
          tester.widget<StudioLoading>(find.byType(StudioLoading)).label,
          'Reconnecting',
        );

        if (leaveChat) {
          await tester.binding.handlePopRoute();
          await tester.pump();
          expect(controller.notificationChat, isNull);
        }
        fixture.connectDelay!.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        // Recovery is driven by screen entry and the owner's scheduled retries.
        // Snapshot encoding can finish on a real isolate while bounded pumps
        // advance the mounted conversation's fake clock.
        for (
          var attempt = 0;
          attempt < 100 &&
              (controller.notificationChat != null ||
                  controller.connectionStatus.phase ==
                      ServerConnectionPhase.reconnecting);
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(controller.notificationChat, isNull);
        expect(
          controller.connectionStatus.phase,
          isNot(ServerConnectionPhase.reconnecting),
        );
        if (leaveChat) {
          expect(controller.current!.chat, isNull);
          expect(
            find.byKey(const ValueKey('chat-filter-profile')),
            findsOneWidget,
          );
          expect(
            fixture.calls.where((call) => call.$2 == 'session.resume'),
            isEmpty,
          );
        } else {
          final chat = controller.current!.chat!;
          expect(chat.key.sessionId, 'newest');
          expect(chat.runtime.opening, isFalse);
          expect(chat.runtime.openingError, isNull);
          expect(chat.composer.observation.text, 'Keep this unsent draft');
          expect(
            chat.reading.messages.single['content'],
            'Saved recovery answer',
          );
          final answer = find.textContaining(
            'Saved recovery answer',
            findRichText: true,
          );
          for (
            var attempt = 0;
            attempt < 100 && answer.evaluate().isEmpty;
            attempt++
          ) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(answer, findsOneWidget);
          expect(find.text('Reconnecting to Prestige'), findsNothing);
          expect(
            fixture.calls.where((call) => call.$2 == 'session.resume'),
            isNotEmpty,
          );
        }
        expect(
          fixture.calls.where((call) => call.$2 == 'prompt.submit'),
          isEmpty,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'context ring has its own target beside the model inside the composer',
    (tester) async {
      await controller.createChat(canDispatch: () => true);
      await show(tester);
      await tester.pumpAndSettle();
      final composer = tester.getRect(
        find.byKey(const ValueKey('conversation-composer')),
      );
      final ring = tester.getRect(
        find.byKey(const ValueKey('context-ring-details')),
      );
      final model = tester.getRect(
        find.byKey(const Key('chat-intelligence-button')),
      );
      final send = tester.getRect(find.byTooltip('Send'));
      expect(ring.height, greaterThanOrEqualTo(48));
      expect(ring.width, greaterThanOrEqualTo(48));
      expect(composer.contains(ring.topLeft), isTrue);
      expect(composer.contains(ring.bottomRight), isTrue);
      expect(ring.right, lessThanOrEqualTo(model.left));
      expect(model.right, lessThanOrEqualTo(send.left));
      expect(find.byType(ContextRing), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('chat header opens project picker without switching profile', (
    tester,
  ) async {
    final chat = await controller.createChat(
      inProject: controller.current!.projects.first,
      canDispatch: () => true,
    );
    await show(tester);
    await tester.pumpAndSettle();
    final header = find.descendant(
      of: find.byType(AppBar),
      matching: find.text('Mobile app'),
    );
    expect(header, findsOneWidget);
    expect(find.byTooltip('Switch profile'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('chat-project-picker')));
    await tester.pumpAndSettle();
    expect(controller.current!.chat, same(chat));
    expect(find.text('work'), findsNothing);
    expect(find.text('Move to project'), findsOneWidget);
    expect(find.byKey(const ValueKey('move-project-p2')), findsNothing);
    await tester.tap(find.byTooltip('Cancel project selection'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-filter-profile')), findsOneWidget);
  });

  testWidgets('reopened chat resolves its project from server membership', (
    tester,
  ) async {
    await controller.openSession(
      ProfileSessionKey(controller.current!.scope, 'project-only'),
    );
    await show(tester);
    await tester.pumpAndSettle();
    expect(find.text('Mobile app'), findsOneWidget);
    expect(controller.current!.chat!.projectId, 'p2');
  });

  testWidgets(
    'conversation keeps known project after workspace refresh fails',
    (tester) async {
      final chat = (await controller.openSession(
        ProfileSessionKey(controller.current!.scope, 'project-only'),
      ))!;
      await show(tester);
      await tester.pumpAndSettle();
      expect(find.text('Mobile app'), findsOneWidget);
      fixture.failProjects = true;
      await tester.runAsync(controller.refresh);
      await tester.pumpAndSettle();
      expect(controller.current!.chat, same(chat));
      expect(find.text('Mobile app'), findsOneWidget);
      expect(find.byIcon(ProjectIconGlyphs.of('rocket')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'conversation keeps known project while reopening saved reading',
    (tester) async {
      fixture.recoveryHistory = [
        {'id': 1, 'role': 'assistant', 'content': 'Saved project answer'},
      ];
      final key = ProfileSessionKey(controller.current!.scope, 'project-only');
      await controller.openSession(key);
      await show(tester);
      await tester.pumpAndSettle();
      expect(find.text('Mobile app'), findsOneWidget);
      fixture.resumeGate = Completer<void>();
      addTearDown(() {
        if (!fixture.resumeGate!.isCompleted) fixture.resumeGate!.complete();
      });
      final opening = controller.openSessionForReading(
        key,
        isCurrentRequest: () => true,
        onReadingAvailable: (_) {},
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.current!.chat!.runtime.opening, isTrue);
      expect(find.text('Mobile app'), findsOneWidget);
      expect(find.byIcon(ProjectIconGlyphs.of('rocket')), findsOneWidget);
      fixture.resumeGate!.complete();
      await tester.runAsync(() => opening);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('chat project appearance ${brightness.name} at $scale text', (
        tester,
      ) async {
        await controller.openSession(
          ProfileSessionKey(controller.current!.scope, 'project-only'),
        );
        await tester.binding.setSurfaceSize(
          Size(scale == 1 ? 390 : 320, scale == 1 ? 844 : 1000),
        );
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: RepaintBoundary(key: captureKey, child: child),
            ),
            home: ProfileWorkspaceScreen(
              controller: controller,
              createBotsSession: () => BotsSession((_) async => const []),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final picker = find.byKey(const ValueKey('chat-project-picker'));
        final icon = find.descendant(
          of: picker,
          matching: find.byIcon(ProjectIconGlyphs.of('rocket')),
        );
        expect(icon, findsOneWidget);
        expect(tester.widget<Icon>(icon).color, const Color(0xff22c55e));
        final iconRect = tester.getRect(icon);
        final labelRect = tester.getRect(find.text('Mobile app'));
        final pickerRect = tester.getRect(picker);
        expect(iconRect.right, lessThan(labelRect.left));
        expect(picker.hitTestable(), findsOneWidget);
        expect(pickerRect.height, greaterThanOrEqualTo(48));
        expect(pickerRect.contains(iconRect.center), isTrue);
        expect(pickerRect.contains(labelRect.center), isTrue);
        expect(tester.takeException(), isNull);

        final gate = Completer<void>();
        fixture.projectGate = gate;
        fixture.failProjects = true;
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        await tester.tap(find.byTooltip('Chat actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Refresh workspace'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('Mobile app'), findsOneWidget);
        expect(icon, findsOneWidget);
        expect(tester.getRect(picker), pickerRect);
        expect(
          tester.widget<StudioLoading>(find.byType(StudioLoading)).label,
          'Refreshing workspace',
        );
        final refresh = controller.refresh();
        gate.complete();
        await settleWorkspaceRefresh(tester);
        await refresh;
        expect(controller.current!.projectsError, isNotNull);
        expect(find.text('Mobile app'), findsOneWidget);
        expect(icon, findsOneWidget);
        expect(find.byType(StudioLoading), findsNothing);
        if (capture) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(captureKey),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            try {
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final directory = Directory('build/chat-project-review');
              await directory.create(recursive: true);
              await File(
                '${directory.path}/${brightness.name}-$scale.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }

        fixture.projectGate = null;
        fixture.failProjects = false;
        await tester.tap(find.byTooltip('Chat actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Refresh workspace'));
        await settleWorkspaceRefresh(tester);
        expect(controller.current!.projectsError, isNull);
        expect(find.text('Mobile app'), findsOneWidget);
        expect(icon, findsOneWidget);
        await tester.tap(icon);
        await tester.pumpAndSettle();
        expect(find.text('Move to project'), findsOneWidget);
        expect(controller.current!.chat!.projectId, 'p2');
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets('unassigned chat does not inherit the selected project', (
    tester,
  ) async {
    await controller.selectProject(controller.current!.projects.first);
    await controller.openSession(
      ProfileSessionKey(controller.current!.scope, 'old'),
    );
    await show(tester);
    await tester.pumpAndSettle();
    expect(find.text('Unassigned'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('chat-project-picker')),
        matching: find.byType(Icon),
      ),
      findsNothing,
    );
  });

  testWidgets('project lookup failure keeps the chat accessible', (
    tester,
  ) async {
    fixture.failProjects = true;
    await controller.switchProfile('personal');
    await controller.openSession(
      ProfileSessionKey(controller.current!.scope, 'newest'),
    );
    await show(tester);
    await tester.pumpAndSettle();
    expect(find.text('Project unavailable'), findsOneWidget);
    expect(find.byTooltip('Open navigation menu'), findsOneWidget);
  });

  testWidgets('grouped browser keeps project actions and chats together', (
    tester,
  ) async {
    await show(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-filter-profile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-menu-personal')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close filters'));
    await tester.pumpAndSettle();
    expect(find.text('Projects'), findsNothing);
    expect(find.text('Recents'), findsNothing);
    await revealChatProject(tester, 'personal', 'p2');
    expect(find.text('Project-only chat'), findsOneWidget);
    expect(controller.current!.selectedProject, isNull);
  });
  testWidgets('project failure keeps chats readable and exposes retry', (
    tester,
  ) async {
    fixture.failProjects = true;
    await show(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not finish loading'), findsWidgets);
    expect(find.text('No chats here yet'), findsNothing);
    expect(find.text('Retry'), findsWidgets);
  });
}

class _ProjectFilterFixture extends ProfileBrowserFixture {
  Completer<void>? resumeGate;
  Completer<void>? projectGate;
  Completer<void>? heldListRead;
  bool heldListEntered = false;
  bool backgroundBlocked = false;
  int workListReads = 0;
  @override
  List<Map<String, dynamic>> projects(String profile) => [
    for (final project in super.projects(profile))
      {
        ...project,
        if (project['id'] == 'p2') ...{'icon': 'rocket', 'color': '#22c55e'},
      },
  ];

  bool connectUnavailable = false;
  Completer<void>? connectDelay;
  List<Map<String, dynamic>> recoveryHistory = [];

  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) =>
      recoveryHistory;

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: base.discover,
      get: (path, query) async {
        if (scope.profileName == 'work' && path == 'sessions') {
          workListReads++;
          final held = heldListRead;
          heldListRead = null;
          if (held != null) {
            heldListEntered = true;
            await held.future;
          }
          if (backgroundBlocked) {
            throw const SocketException('Background access blocked');
          }
        }
        return base.read(path, query);
      },
      rpc: (method, params) async {
        if (method == 'session.resume') await resumeGate?.future;
        if (method == 'projects.tree') await projectGate?.future;
        return base.call(method, params);
      },
      connect: () async {
        if (connectUnavailable) {
          throw const SocketException('Temporary connection failure');
        }
        await connectDelay?.future;
      },
    );
  }

  @override
  List<Map<String, dynamic>> projectSessions(String profile, String id) {
    if (profile == 'work' || id == 'p2') {
      return super.projectSessions(profile, id);
    }
    if (id == 'p4') {
      return sessions(
        profile,
      ).where((r) => {'pinned', 'newest'}.contains(r['id'])).toList();
    }
    return [];
  }
}
