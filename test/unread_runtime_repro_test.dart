import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/chat_status_dot.dart';
import 'package:wing/core/models/chat_list_status.dart';
import 'helpers/pump_markdown_widget.dart';
import 'profile_workspace_controller_test.dart' show Host;

void main() => unreadRuntimeContract();

void unreadRuntimeContract({
  Future<void> Function(WidgetTester, String)? onVerified,
}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final held in [false, true]) {
    testWidgets(
      'visible saved answer clears unread with runtime ${held ? 'opening' : 'refused'}',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final appPreferences = AppPreferences(preferences);
        final host = Host()
          ..profiles = ['a']
          ..running = false;
        final now = DateTime.now().millisecondsSinceEpoch / 1000;
        host.indexedSessions = [
          {
            'id': 'same',
            'title': 'Recorded chat',
            'profile': 'a',
            'unread': true,
            'last_active': now,
            'last_read_at': now - 60,
            'message_count': 2,
          },
        ];
        host.historyMessages = [
          {
            'id': 700,
            'role': 'user',
            'content': 'approved',
            'timestamp': now - 2,
          },
          {
            'id': 701,
            'role': 'assistant',
            'content':
                'The approval went through. The repository is verified and synchronized.',
            'timestamp': now - 1,
          },
        ];
        final writes = <Map<String, dynamic>>[];
        final receipt = Completer<void>();
        host.ownedPatch = (path, body, canDispatch, onDispatched) async {
          if (!canDispatch()) throw StateError('Read request retired');
          onDispatched();
          writes.add({'path': path, ...body});
          host.indexedSessions![0] = {
            ...host.indexedSessions![0],
            'unread': false,
            'last_read_at': now,
          };
          if (!receipt.isCompleted) receipt.complete();
          return {'ok': true};
        };
        final controller = ProfileWorkspaceController(
          connectionIdentity: 'unread-runtime-emulator',
          access: ConnectionAccess(
            connection: SavedConnection(
              id: 'fixture',
              label: 'Emulator',
              host: 'localhost',
              port: 1,
              apiKey: '',
            ),
            dashboardOAuth: null,
          ),
          preferences: preferences,
          appPreferences: appPreferences,
          gatewayFactory: host.gateway,
        );
        addTearDown(() {
          controller.dispose();
          appPreferences.dispose();
        });
        await controller.initialize();
        final pending = Completer<void>();
        if (held) {
          host.resumeDelay = pending;
        } else {
          host.resumeError = JsonRpcError(
            'gateway.ready',
            'Canonical session authority is unavailable at this address',
            reason: 'session_authority_unavailable',
          );
        }
        addTearDown(() {
          if (!pending.isCompleted) pending.complete();
        });
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: wingTheme(Brightness.dark),
            home: ProfileWorkspaceScreen(
              controller: controller,
              createBotsSession: () => BotsSession((_) async => const []),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('chat-a-same')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('chat-a-same')));
        for (
          var i = 0;
          i < 100 &&
              find
                  .text(
                    'The approval went through. The repository is verified and synchronized.',
                    findRichText: true,
                  )
                  .evaluate()
                  .isEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 30));
        }
        await tester.settleMarkdown();
        final answer = find.text(
          'The approval went through. The repository is verified and synchronized.',
          findRichText: true,
        );
        expect(answer.hitTestable(), findsOneWidget);
        expect(controller.current!.chat!.runtime.offline, isTrue);
        await tester.runAsync(
          () => receipt.future.timeout(const Duration(seconds: 10)),
        );
        await tester.pump();
        expect(
          writes,
          hasLength(1),
          reason:
              'A visible saved answer must acknowledge shared read status even when live attachment is unavailable',
        );
        expect(writes.single['path'], 'sessions/same');
        expect(writes.single['unread'], isFalse);
        expect(writes.single['expected_revision'], 0);
        expect(writes.single['expected_generation'], 0);
        expect(writes.single['profile'], 'a');
        expect(controller.current!.sessions.single['unread'], isFalse);
        expect(
          controller
              .recentChats()
              .singleWhere(
                (row) =>
                    row.key ==
                    ProfileSessionKey(controller.current!.scope, 'same'),
              )
              .unread,
          isFalse,
        );
        if (!pending.isCompleted) pending.complete();
        await tester.tap(find.byTooltip('Open navigation menu'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Chats').hitTestable(), findsOneWidget);
        await tester.tap(find.text('Chats').hitTestable());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final row = find.byKey(const ValueKey('chat-a-same'));
        expect(row.hitTestable(), findsOneWidget);
        expect(
          tester
              .widget<ChatStatusDot>(
                find.descendant(of: row, matching: find.byType(ChatStatusDot)),
              )
              .status,
          isNot(ChatListStatus.unread),
        );
        await tester.tap(find.byTooltip('Open navigation menu'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Recents').last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Recorded chat').hitTestable(), findsOneWidget);
        expect(find.text('Read').hitTestable(), findsOneWidget);
        expect(find.text('New answer'), findsNothing);
        await onVerified?.call(tester, held ? 'opening' : 'refused');
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
