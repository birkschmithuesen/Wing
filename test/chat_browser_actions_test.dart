import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/widgets/chat_profile_bar.dart';
import 'package:wing/core/widgets/server_connection_label.dart';
import 'package:wing/core/widgets/wing_app_bar.dart';
import 'package:wing/core/widgets/deleted_chat_recovery_notice.dart';
import 'package:wing/core/services/chat_browser_data.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_browser.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';

import 'support/browser_mutations_fixture.dart';
import 'support/chat_browser_interactions.dart';

void main() {
  late BrowserMutationsFixture host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    host = BrowserMutationsFixture();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'host',
          label: 'Test server',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'browser-actions',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
  });
  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  const capture = bool.fromEnvironment('BROWSER_ACTIONS_REVIEW');
  setUpAll(() async {
    if (!capture) return;
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
      'WingIcons': 'assets/fonts/wing-icons.ttf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            Future.value(
              ByteData.sublistView(File(entry.value).readAsBytesSync()),
            ),
          ))
          .load();
    }
  });

  Future<void> show(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) async {
    await tester.binding.setSurfaceSize(Size(scale == 1 ? 390 : 320, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('capture'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: wingTheme(brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: ProfileWorkspaceBrowser(
            onOpenBotChat: (_) {},
            createData: () => ChatBrowserData(controller),
            connectionLabel: controller.connection.label,
            connectionIcon: controller.connection.icon,
            connectionStatus: controller.connectionStatus,
            createColors: controller.createProfileColors,
            deletionRecovery: DeletedChatRecoveryNotice(
              presentation: controller.deletedDraftCleanupPresentation,
            ),
            newProject: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-profile-personal')));
    await tester.pumpAndSettle();
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (!capture) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('capture')),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/browser-actions-review/$name.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> menu(WidgetTester tester, String id) async {
    final row = find.byKey(ValueKey('chat-personal-$id'));
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('chat-list-false')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: row, matching: find.byTooltip('Chat actions')),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'New chat long press gives haptic feedback when toggling New project',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final haptics = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') haptics.add(call);
          return null;
        },
      );
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });

      try {
        await show(tester);
        final chat = find.byKey(const ValueKey('workspace-new-chat'));
        final project = find.byKey(const ValueKey('workspace-new-project'));
        expect(haptics, isEmpty);

        await tester.longPress(chat);
        await tester.pumpAndSettle();
        expect(project, findsOneWidget);
        expect(haptics, hasLength(1));

        await tester.longPress(chat);
        await tester.pumpAndSettle();
        expect(project, findsNothing);
        expect(haptics, hasLength(2));
        expect(
          host.wireCalls.where((method) => method == 'session.create'),
          isEmpty,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'New project FAB reveal and dismissal ${brightness.name} $scale',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            await show(tester, brightness: brightness, scale: scale);
            final chat = find.byKey(const ValueKey('workspace-new-chat'));
            final project = find.byKey(const ValueKey('workspace-new-project'));
            final initial = tester.getRect(chat);
            expect(project, findsNothing);
            await tester.longPress(chat);
            await tester.pumpAndSettle();
            expect(project, findsOneWidget);
            final expanded = tester.getRect(chat);
            expect(expanded.left, closeTo(initial.left, 0.01));
            expect(expanded.top, closeTo(initial.top, 0.01));
            expect(expanded.width, closeTo(initial.width, 0.01));
            expect(expanded.height, closeTo(initial.height, 0.01));
            expect(tester.getRect(project).bottom, lessThan(initial.top));
            expect(
              tester.widget<FloatingActionButton>(project).tooltip,
              'New project',
            );
            expect(
              host.wireCalls.where((method) => method == 'session.create'),
              isEmpty,
            );
            await screenshot(tester, 'project-fab-${brightness.name}-$scale');
            await tester.binding.handlePopRoute();
            await tester.pumpAndSettle();
            expect(project, findsNothing);
            await tester.longPress(chat);
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const ValueKey('workspace-search')));
            await tester.pumpAndSettle();
            expect(project, findsNothing);
            expect(
              host.wireCalls.where((method) => method == 'session.create'),
              isEmpty,
            );
            await tester.pumpWidget(const SizedBox.shrink());
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }

  testWidgets(
    'one New chat tap opens the selected profile while its list is refreshing',
    (tester) async {
      final gate = Completer<void>();
      host.pageDelays[('work', 0)] = gate;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('chat-profile-work')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('workspace-new-chat')));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(gate.isCompleted, isFalse);
      expect(
        controller.current?.chat?.key.workspace.profileName,
        'work',
        reason: 'a single tap must open the chat before list reads finish',
      );
      expect(controller.current?.chat?.key.sessionId, 'new-chat');
      expect(
        host.calls.where((call) => call.$2 == 'session.create'),
        hasLength(1),
      );
      gate.complete();
      await tester.pumpAndSettle();
      expect(controller.current?.chat?.key.sessionId, 'new-chat');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('New chat supersedes an older refresh of the current profile', (
    tester,
  ) async {
    await show(tester);
    final gate = Completer<void>();
    host.pageDelays[('personal', 0)] = gate;
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final refresh = controller.refresh();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('workspace-new-chat')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(gate.isCompleted, isFalse);
    expect(controller.current?.chat?.key.sessionId, 'new-chat');
    gate.complete();
    await refresh;
    await tester.pumpAndSettle();
    expect(controller.current?.chat?.key.sessionId, 'new-chat');
    expect(controller.error, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('repeated New chat taps create one chat in the chosen profile', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('chat-profile-work')));
    await tester.pump();
    final gate = Completer<void>();
    host.rpcDelays['session.create'] = gate;
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final fab = find.byKey(const ValueKey('workspace-new-chat'));
    await tester.tap(fab);
    await tester.tap(fab);
    await tester.pump();
    expect(
      host.wireCalls.where((call) => call == 'session.create'),
      hasLength(1),
    );
    gate.complete();
    await tester.pumpAndSettle();
    expect(controller.current?.chat?.key.workspace.profileName, 'work');
    expect(
      host.calls.where((call) => call.$2 == 'session.create'),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'confirmed action releases controls before the list refresh finishes',
    (tester) async {
      await show(tester);
      await menu(tester, 'newest');
      final gate = Completer<void>();
      host.pageDelays[('personal', 0)] = gate;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      await tester.tap(find.text('Pin'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(host.updates, hasLength(1));
      expect(
        tester
            .widget<FloatingActionButton>(
              find.byKey(const ValueKey('workspace-new-chat')),
            )
            .onPressed,
        isNotNull,
        reason:
            'a confirmed action must not lock the list during background reads',
      );
      expect(find.byType(StudioLoading), findsNothing);
      expect(gate.isCompleted, isFalse);
      final row = find.byKey(const ValueKey('chat-personal-newest'));
      // Pin moves this retained chat into the first group. Its old viewport
      // position need not remain mounted while the background read is held.
      await tester.scrollUntilVisible(
        row,
        -200,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('chat-list-false')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pump();
      expect(gate.isCompleted, isFalse);
      expect(row.hitTestable(), findsOneWidget);
      expect(tester.widget<ListTile>(row).onTap, isNotNull);
      expect(find.byType(StudioLoading), findsNothing);
      expect(host.updates, hasLength(1));
      gate.complete();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('dismissing an action menu does not reload the list', (
    tester,
  ) async {
    await show(tester);
    await menu(tester, 'newest');
    host.reads.clear();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(host.reads.where((read) => read.$1 == 'sessions'), isEmpty);
  });

  testWidgets(
    'pending submission is visible and failure unlocks without refreshing',
    (tester) async {
      await show(tester);
      await menu(tester, 'newest');
      final gate = Completer<void>();
      host.mutationDelay = gate;
      host.failMutation = true;
      host.reads.clear();
      await tester.tap(find.text('Pin'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Updating chats…'), findsNothing);
      await tester.pump();
      expect(find.byType(StudioLoading), findsOneWidget);
      expect(find.bySemanticsLabel('Updating chats…'), findsOneWidget);
      expect(
        tester
            .widget<FloatingActionButton>(
              find.byKey(const ValueKey('workspace-new-chat')),
            )
            .onPressed,
        isNull,
      );
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Write rejected'), findsOneWidget);
      expect(
        tester
            .widget<FloatingActionButton>(
              find.byKey(const ValueKey('workspace-new-chat')),
            )
            .onPressed,
        isNotNull,
      );
      expect(host.reads.where((read) => read.$1 == 'sessions'), isEmpty);
    },
  );

  for (final action in ['Rename', 'Mark as unread', 'Archive', 'Delete']) {
    testWidgets('$action releases controls while follow-up reads are pending', (
      tester,
    ) async {
      await show(tester);
      await menu(tester, 'newest');
      final gate = Completer<void>();
      host.pageDelays[('personal', 0)] = gate;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      await tester.tap(
        find.byKey(
          ValueKey(
            'action-${switch (action) {
              'Rename' => 'rename',
              'Mark as unread' => 'unread',
              'Archive' => 'archive',
              'Delete' => 'delete',
              _ => '',
            }}',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      if (action == 'Rename') {
        await tester.enterText(
          find.byKey(const ValueKey('chat-rename-title')),
          'Renamed chat',
        );
        await tester.tap(find.byKey(const ValueKey('chat-rename-save')));
      } else if (action == 'Delete') {
        await tester.tap(find.byTooltip('Delete chat'));
      }
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      if (action == 'Delete') {
        await waitForChatDeletionCleanup(
          tester,
          controller,
          ProfileSessionKey(controller.current!.scope, 'newest'),
        );
      }
      expect(
        tester
            .widget<FloatingActionButton>(
              find.byKey(const ValueKey('workspace-new-chat')),
            )
            .onPressed,
        isNotNull,
      );
      expect(find.text('Refreshing chats…'), findsNothing);
      expect(find.byType(StudioLoading), findsNothing);
      expect(find.bySemanticsLabel('Refreshing chats…'), findsNothing);
      if (action == 'Archive' || action == 'Delete') {
        expect(
          find.byKey(const ValueKey('chat-personal-newest')),
          findsNothing,
        );
      } else if (action == 'Rename') {
        expect(find.text('Renamed chat'), findsOneWidget);
      }
      gate.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'Chats pulse stays in the instance row ${brightness.name} $scale',
        (tester) async {
          await show(tester, brightness: brightness, scale: scale);
          final search = find.byKey(const ValueKey('workspace-search'));
          final profiles = find.byType(ChatProfileBar);
          final instance = find.byType(ServerConnectionLabel);
          final slot = find.byKey(const ValueKey('studio-loading-slot'));
          final before = {
            'search': tester.getRect(search),
            'profiles': tester.getRect(profiles),
            'instance': tester.getRect(instance),
            'slot': tester.getRect(slot),
          };
          await menu(tester, 'newest');
          final gate = Completer<void>();
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });
          host.mutationDelay = gate;
          host.failMutation = true;
          await tester.tap(find.text('Pin'));
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pump();
          final pulse = find.byType(StudioLoading);
          expect(pulse, findsOneWidget);
          expect(
            find.ancestor(of: pulse, matching: find.byType(WingAppBar)),
            findsOneWidget,
          );
          final glyph = tester.getRect(pulse);
          expect(glyph.center.dy, closeTo(before['instance']!.center.dy, 1));
          expect(glyph.left, greaterThanOrEqualTo(before['profiles']!.right));
          expect(glyph.overlaps(before['search']!), isFalse);
          expect(
            tester.getRect(find.byType(WingAppBar)).contains(glyph.center),
            isTrue,
          );
          for (final entry in {
            'search': search,
            'profiles': profiles,
            'instance': instance,
            'slot': slot,
          }.entries) {
            expect(tester.getRect(entry.value), before[entry.key]);
          }
          await screenshot(
            tester,
            'header-progress-${brightness.name}-$scale-pending',
          );
          gate.complete();
          await tester.pumpAndSettle();
          expect(pulse, findsNothing);
          for (final entry in {
            'search': search,
            'profiles': profiles,
            'instance': instance,
            'slot': slot,
          }.entries) {
            expect(tester.getRect(entry.value), before[entry.key]);
          }
          await screenshot(
            tester,
            'header-progress-${brightness.name}-$scale-ready',
          );
        },
      );

      testWidgets(
        'refresh status ${brightness.name} $scale remains fixed and interactive',
        (tester) async {
          await show(tester, brightness: brightness, scale: scale);
          await tester.tap(find.byTooltip('Chat list options'));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('chat-menu-show-details')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('chat-menu-tokens')));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Close filters'));
          await tester.pumpAndSettle();
          final gate = Completer<void>();
          host.pageDelays[('personal', 0)] = gate;
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });
          await controller.mutateSession(
            ProfileSessionKey(controller.current!.scope, 'newest'),
            changes: {'pinned': true},
            canDispatch: () => true,
          );
          await tester.pump(const Duration(milliseconds: 200));
          final progress = find.byType(StudioLoading);
          expect(find.text('Refreshing chats…'), findsNothing);
          expect(progress, findsNothing);
          final bounds = tester.getRect(
            find.byKey(const ValueKey('chat-list-false')),
          );
          await tester.drag(
            find.byKey(const ValueKey('chat-list-false')),
            const Offset(0, -350),
          );
          await tester.pump();
          expect(progress, findsNothing);
          expect(
            tester.getRect(find.byKey(const ValueKey('chat-list-false'))),
            bounds,
          );
          final scrollable = find.descendant(
            of: find.byKey(const ValueKey('chat-list-false')),
            matching: find.byType(Scrollable),
          );
          final offset = tester
              .state<ScrollableState>(scrollable)
              .position
              .pixels;
          await screenshot(tester, '${brightness.name}-$scale-refreshing');
          host.pageFailures.add(('personal', 0));
          gate.complete();
          await tester.pumpAndSettle();
          expect(
            tester.state<ScrollableState>(scrollable).position.pixels,
            offset,
          );
          expect(
            find.text('Could not refresh chats for personal.'),
            findsOneWidget,
          );
          expect(
            tester
                .widget<FloatingActionButton>(
                  find.byKey(const ValueKey('workspace-new-chat')),
                )
                .onPressed,
            isNotNull,
          );
          await screenshot(tester, '${brightness.name}-$scale-failure');
          host.pageFailures.clear();
          await tester.tap(find.text('Retry'));
          await tester.pumpAndSettle();
          expect(
            find.text('Could not refresh chats for personal.'),
            findsNothing,
          );
          expect(
            host.updates,
            hasLength(1),
            reason: 'Retry does not repeat the action',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
