import 'package:wing/core/widgets/deleted_chat_recovery_notice.dart';
import 'package:wing/core/services/chat_browser_data.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/screens/profile_workspace_browser.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/models/profile_selection.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';

import 'support/browser_mutations_fixture.dart';

void main() {
  testWidgets(
    'a superseded held profile-selection write cannot retarget a browser menu',
    (tester) async {
      final previousPlatform = SharedPreferencesStorePlatform.instance;
      SharedPreferences.setMockInitialValues({});
      final platform = _HeldWorkSelection();
      SharedPreferencesStorePlatform.instance = platform;
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      final host = BrowserMutationsFixture();
      final controller = ProfileWorkspaceController(
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
        connectionIdentity: 'browser-captured-menu-owner',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
      );
      addTearDown(() async {
        platform.release();
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        appPreferences.dispose();
        SharedPreferences.setMockInitialValues({});
        SharedPreferencesStorePlatform.instance = previousPlatform;
      });

      await controller.initialize();
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
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
      );
      await tester.pumpAndSettle();

      // Both profiles intentionally contain the same server session ID. The
      // clicked row, rather than whichever profile is current later, owns it.
      expect(controller.current!.scope.profileName, 'personal');
      expect(
        host.sessions('personal').any((row) => row['id'] == 'newest'),
        true,
      );
      expect(host.sessions('work').any((row) => row['id'] == 'newest'), true);
      final workRow = find.byKey(const ValueKey('chat-work-newest'));
      final scrollable = find.descendant(
        of: find.byKey(const ValueKey('chat-list-false')),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(workRow, 200, scrollable: scrollable);
      await tester.pumpAndSettle();
      await tester.ensureVisible(workRow);
      await tester.pump();
      final actions = find.descendant(
        of: workRow,
        matching: find.byTooltip('Chat actions'),
      );
      expect(actions.hitTestable(), findsOneWidget);

      platform.holdWorkSelection();
      await tester.tap(actions);
      for (
        var frame = 0;
        frame < 10 && !platform.entered.isCompleted;
        frame++
      ) {
        await tester.pump();
      }
      expect(
        platform.entered.isCompleted,
        true,
        reason: 'the work switch must reach its actual held persistence await',
      );
      expect(controller.current!.scope.profileName, 'work');
      expect(find.byKey(const ValueKey('action-pin')), findsNothing);
      expect(host.updates, isEmpty);

      // Another supported navigation finishes while the older menu invocation
      // is suspended. Its later continuation must not borrow this new owner.
      expect(await controller.switchProfile('personal'), true);
      expect(controller.current!.scope.profileName, 'personal');
      expect(host.updates, isEmpty);
      platform.release();
      await tester.pumpAndSettle();

      // A repair may retire the stale menu entirely or keep a correctly scoped
      // menu. If it appears, exercise its real public mutation callback.
      final pin = find.byKey(const ValueKey('action-pin'));
      if (pin.evaluate().isNotEmpty) {
        expect(pin.hitTestable(), findsOneWidget);
        await tester.tap(pin);
        await tester.pumpAndSettle();
      }

      // Check the transport effect before any notice or exception assertion.
      expect(
        host.updates.where((update) => update.$1 == 'personal'),
        isEmpty,
        reason: 'a work-row action must never dispatch to the personal profile',
      );
      expect(host.changes['personal']?['newest']?['pinned'], isNot(true));
      expect(host.updates.every((update) => update.$1 == 'work'), true);
      expect(controller.current!.scope.profileName, 'personal');
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'an older admitted selection write cannot replace the latest restart selection',
    () async {
      final previousPlatform = SharedPreferencesStorePlatform.instance;
      SharedPreferences.setMockInitialValues({});
      final platform = _HeldWorkSelection();
      SharedPreferencesStorePlatform.instance = platform;
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      final host = BrowserMutationsFixture();
      const identity = 'browser-captured-restart-selection';
      final controller = ProfileWorkspaceController(
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
        connectionIdentity: identity,
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
      );
      addTearDown(() {
        platform.release();
        controller.dispose();
        appPreferences.dispose();
        SharedPreferences.setMockInitialValues({});
        SharedPreferencesStorePlatform.instance = previousPlatform;
      });
      await controller.initialize();
      expect(controller.current!.scope.profileName, 'personal');
      platform.holdWorkSelection();
      final older = controller.switchProfile('work');
      await platform.entered.future;
      expect(controller.current!.scope.profileName, 'work');
      expect(await controller.switchProfile('personal'), true);
      expect(controller.current!.scope.profileName, 'personal');
      platform.release();
      await older;

      // A fresh reader must observe durable platform data, not the optimistic
      // SharedPreferences cache that the second write already changed locally.
      await preferences.reload();
      expect(
        ProfileSelectionCodec.canonicalName(
          preferences.get(ProfileSelectionCodec.storageKey(identity)),
        ),
        'personal',
        reason: 'restart must restore the latest completed navigation',
      );
      expect(controller.current!.scope.profileName, 'personal');
      expect(host.updates, isEmpty);
    },
  );
}

class _HeldWorkSelection extends InMemorySharedPreferencesStore {
  _HeldWorkSelection() : super.empty();

  final entered = Completer<void>();
  Completer<void>? _gate;

  void holdWorkSelection() => _gate = Completer<void>();

  void release() {
    final gate = _gate;
    _gate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final gate = _gate;
    if (key.startsWith('flutter.workspace_profile_selection_v1_') &&
        value == 'work' &&
        gate != null) {
      if (!entered.isCompleted) entered.complete();
      await gate.future;
    }
    return super.setValue(valueType, key, value);
  }
}
