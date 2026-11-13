import 'package:wing/core/widgets/deleted_chat_recovery_notice.dart';
import 'package:wing/core/services/chat_browser_data.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/screens/profile_workspace_browser.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';

import 'support/profile_browser_fixture.dart';

void main() {
  const identity = 'browser-preferences';
  const storageKey = 'flutter.chat_list_target_$identity';
  late _BrowserPreferencesPlatform platform;
  late SharedPreferences preferences;
  late AppPreferences owner;
  late ProfileWorkspaceController controller;
  late SharedPreferencesStorePlatform previousPlatform;

  setUp(() async {
    previousPlatform = SharedPreferencesStorePlatform.instance;
    SharedPreferences.resetStatic();
    platform = _BrowserPreferencesPlatform(storageKey);
    SharedPreferencesStorePlatform.instance = platform;
    preferences = await SharedPreferences.getInstance();
    owner = AppPreferences(preferences);
    final fixture = ProfileBrowserFixture();
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
      connectionIdentity: identity,
      preferences: preferences,
      appPreferences: owner,
      gatewayFactory: fixture.gateway,
    );
    await controller.initialize();
  });
  tearDown(() {
    if (!platform.release.isCompleted) platform.release.complete();
    controller.dispose();
    owner.dispose();
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesStorePlatform.instance = previousPlatform;
  });

  Future<void> show(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(460, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.light),
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
  }

  Future<void> openProfiles(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('chat-filter-profile')));
    await tester.pumpAndSettle();
  }

  Future<void> settlePreferenceWrites(WidgetTester tester) async {
    final channel = owner.browserPreferencesFor(identity);
    // The held platform completer belongs to the real setup zone; the owner
    // FIFO belongs to the widget zone. Give both their own scheduling turn.
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.pump();
      if (!channel.value.busy) {
        await tester.pumpAndSettle();
        return;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
    }
    throw TimeoutException('Browser preference commands did not settle');
  }

  testWidgets('later browser filter choice survives an older held save', (
    tester,
  ) async {
    await show(tester);
    platform.holdFirst = true;
    await openProfiles(tester);
    await tester.tap(find.byKey(const ValueKey('chat-menu-personal')));
    await tester.pump();
    expect(platform.entered.isCompleted, isTrue);
    await tester.tap(find.byKey(const ValueKey('chat-menu-work')));
    await tester.pump();
    await tester.tap(find.byTooltip('Close filters'));
    await tester.pump();
    platform.release.complete();
    await settlePreferenceWrites(tester);
    await preferences.reload();
    final physical =
        jsonDecode((await platform.getAll())[storageKey] as String) as Map;
    expect(platform.writes, hasLength(2));
    expect(physical['profile'], ['personal', 'work']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'false browser preference acknowledgement retains confirmed filter',
    (tester) async {
      await show(tester);
      platform.failNext = true;
      await openProfiles(tester);
      await tester.tap(find.byKey(const ValueKey('chat-menu-personal')));
      await settlePreferenceWrites(tester);
      await tester.tap(find.byTooltip('Close filters'));
      await tester.pumpAndSettle();
      expect((await platform.getAll()).containsKey(storageKey), isFalse);
      expect(platform.writes, hasLength(1));
      expect(find.text('Profile 1'), findsNothing);
      expect(find.text('Profile'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'malformed browser preference is explicit and remains untouched',
    (tester) async {
      final raw = jsonEncode({
        'grouping': 'status',
        'ordering': 'not-an-order',
        'show': ['updated'],
        'status': <String>[],
        'profile': <String>[],
        'project': <String>[],
      });
      await preferences.setString('chat_list_target_$identity', raw);
      platform.writes.clear();
      await show(tester);
      expect((await platform.getAll())[storageKey], raw);
      expect(platform.writes, isEmpty);
      expect(find.text('Reset chat view'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'open filter menu retracts a choice after failed acknowledgement',
    (tester) async {
      await show(tester);
      platform.holdFirst = true;
      platform.failNext = true;
      await openProfiles(tester);
      final personal = find.byKey(const ValueKey('chat-menu-personal'));
      bool selected() =>
          tester
              .widget<Semantics>(
                find
                    .ancestor(of: personal, matching: find.byType(Semantics))
                    .first,
              )
              .properties
              .selected ==
          true;

      await tester.tap(personal);
      await tester.pump();
      expect(platform.entered.isCompleted, isTrue);
      expect(
        selected(),
        isTrue,
        reason: 'the open menu shows the admitted pending choice',
      );
      expect(find.text('Profile 1'), findsOneWidget);
      platform.release.complete();
      await settlePreferenceWrites(tester);

      expect((await platform.getAll()).containsKey(storageKey), isFalse);
      expect(platform.writes, hasLength(1));
      expect(find.text('Profile 1'), findsNothing);
      expect(find.byTooltip('Close filters'), findsOneWidget);
      expect(personal, findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(
        selected(),
        isFalse,
        reason: 'the still-open menu must reflect the confirmed rollback',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _BrowserPreferencesPlatform extends InMemorySharedPreferencesStore {
  _BrowserPreferencesPlatform(this.key) : super.empty();
  final String key;
  final writes = <String>[];
  bool holdFirst = false;
  bool failNext = false;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == this.key) {
      writes.add(value as String);
      if (holdFirst && !entered.isCompleted) {
        entered.complete();
        await release.future;
      }
      if (failNext) {
        failNext = false;
        return false;
      }
    }
    return super.setValue(valueType, key, value);
  }
}
