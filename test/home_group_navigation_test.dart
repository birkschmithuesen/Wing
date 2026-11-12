import 'package:wing/core/widgets/deleted_chat_recovery_notice.dart';
import 'package:wing/core/services/chat_browser_data.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_browser.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'support/profile_browser_fixture.dart';

class _HomeFixture extends ProfileBrowserFixture {
  final resumeDelays = <String, Completer<void>>{};

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: base.discover,
      get: base.read,
      rpc: (method, params) async {
        if (method == 'session.resume') {
          await resumeDelays[scope.profileName]?.future;
        }
        return base.call(method, params);
      },
    );
  }

  @override
  List<Map<String, dynamic>> projects(String profile) => [];

  @override
  List<Map<String, dynamic>> sessions(String profile) => [
    for (var i = 0; i < 2; i++)
      {
        'id': '$profile-$i',
        'title': '$profile chat $i',
        'profile': profile,
        'last_active': now - i * 60,
        'message_count': 2,
        'unread': false,
        'source': 'cli',
      },
  ];
}

void main() {
  testWidgets('a pending chat resume does not lock chats after a Home toggle', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final fixture = _HomeFixture();
    final preferences = await SharedPreferences.getInstance();
    final appPreferences = AppPreferences(preferences);
    addTearDown(appPreferences.dispose);
    final controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'host',
          label: 'Test',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'home-navigation',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: fixture.gateway,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
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
    final delayed = Completer<void>();
    fixture.resumeDelays['work'] = delayed;
    addTearDown(() {
      if (!delayed.isCompleted) delayed.complete();
    });
    await tester.tap(find.text('work chat 0'));
    await tester.pump();
    expect(controller.notificationChat?.key.sessionId, 'work-0');
    expect(controller.notificationChat?.runtime.opening, isTrue);
    expect(delayed.isCompleted, isFalse);
    expect(controller.switching, isFalse);
    final header = find.byKey(const ValueKey('chat-group-project/work/home'));
    await tester.tap(header);
    await tester.pump();
    await tester.tap(find.text('personal chat 0'));
    await tester.pumpAndSettle();
    expect(controller.current!.selectedSession, 'personal-0');
    delayed.complete();
    await tester.pumpAndSettle();
    expect(controller.current!.scope.profileName, 'personal');
    expect(controller.current!.selectedSession, 'personal-0');
  });

  testWidgets(
    'Home headers can collapse and expand before opening either profile',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final fixture = _HomeFixture();
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: SavedConnection(
            id: 'host',
            label: 'Test',
            host: 'localhost',
            port: 1,
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'home-navigation',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: fixture.gateway,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
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
      for (var cycle = 0; cycle < 4; cycle++) {
        for (final profile in ['personal', 'work']) {
          final other = profile == 'personal' ? 'work' : 'personal';
          final heading = find.byKey(
            ValueKey('chat-group-project/$profile/home'),
          );
          await tester.tap(heading);
          await tester.pumpAndSettle();
          expect(find.text('$profile chat 0'), findsNothing);
          final before = fixture.calls
              .where((call) => call.$2 == 'session.resume')
              .length;
          await tester.tap(find.text('$other chat 0'));
          await tester.pumpAndSettle();
          expect(
            fixture.calls.where((call) => call.$2 == 'session.resume').length,
            before + 1,
          );
          expect(controller.current!.scope.profileName, other);
          await tester.tap(heading);
          await tester.pumpAndSettle();
          expect(find.text('$profile chat 0'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      }
    },
  );
}
