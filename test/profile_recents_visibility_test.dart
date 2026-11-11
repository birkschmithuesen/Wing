import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/models/group_notification.dart';
import 'package:wing/core/services/chat_notification_coordinator.dart';
import 'support/recording_turn_notification_sink.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:wing/core/screens/workspace_overview_content.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/widgets/app_drawer.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/workspace_recents_session.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/recent_identity_card.dart';
import 'support/bots_fixture.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/models/session_visibility.dart';
import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/profile_browser_fixture.dart';

class TechnicalSessionsFixture extends ProfileBrowserFixture {
  String messagePreviewText = 'Result';
  bool oldTechnicalHistory = false;
  bool empty = false;
  String technicalSource = 'oneshot';
  final extraRows = <Map<String, dynamic>>[];
  @override
  List<Map<String, dynamic>> searchRows(String profile, String query) => [
    for (final row in sessions(profile))
      if (row['id'] == query) {...row, 'session_id': row['id']},
  ];
  @override
  List<Map<String, dynamic>> sessions(String profile) =>
      profile != 'personal' || empty
      ? []
      : [
          ...extraRows,
          {
            'id': 'user-chat',
            'title': 'User conversation',
            'source': 'desktop',
            'profile': profile,
            'last_active': now - 120,
          },
          {
            'id': 'technical-run',
            'title': 'Technical command',
            'source': technicalSource,
            'parent_session_id': null,
            'profile': profile,
            'last_active': now - 60,
          },
        ];
  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) => [
    {
      'id': 1,
      'role': 'assistant',
      'content': messagePreviewText,
      'timestamp':
          now - (oldTechnicalHistory && id == 'technical-run' ? 90000 : 60),
    },
  ];
}

const _captureLoading = bool.fromEnvironment('CAPTURE_RECENTS_LOADING');

Future<void> _captureRecents(
  WidgetTester tester,
  GlobalKey frame,
  String name,
) async {
  if (!_captureLoading) return;
  await tester.pump(const Duration(milliseconds: 100));
  await tester.runAsync(() async {
    final boundary =
        frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('build/design-previews/recents-loading')
      ..createSync(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  for (final empty in [false, true]) {
    testWidgets('pull refresh works on short Recents empty=$empty', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      final fixture = TechnicalSessionsFixture()..empty = empty;
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: identityTestConnection(),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'short-recents',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: fixture.gateway,
      );
      final bots = BotsSession((_) async => []);
      final recents = WorkspaceRecentsSession(
        controller,
        bots,
        foreground: true,
      );
      final release = Completer<void>();
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await tester.pumpWidget(const SizedBox.shrink());
        recents.dispose();
        bots.dispose();
        controller.dispose();
        appPreferences.dispose();
      });
      await controller.initialize();
      await recents.refresh();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(actions: const [StudioLoadingSlot()]),
            body: WorkspaceActivityContent(
              recents: recents,
              visible: true,
              onOpen: (_, _) {},
              onOpenGroup: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(empty ? 'No recent chats' : 'User conversation'),
        findsOneWidget,
      );
      expect(
        tester
            .state<ScrollableState>(find.byType(Scrollable))
            .position
            .maxScrollExtent,
        0,
      );
      fixture.pageDelays[('personal', 0)] = release;
      final reads = fixture.reads.length;
      await tester.drag(find.byType(ListView), const Offset(0, 350));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(fixture.reads.length, greaterThan(reads));
      expect(find.byType(StudioLoading), findsOneWidget);
      expect(
        find.text(empty ? 'No recent chats' : 'User conversation'),
        findsOneWidget,
      );
      // A second intent joins the owner's already admitted operation.
      final joinedReads = fixture.reads.length;
      final joined = recents.refresh(force: true, retryFailures: true);
      await tester.pump();
      expect(fixture.reads.length, joinedReads);
      release.complete();
      await tester.pumpAndSettle();
      await joined;
      expect(find.byType(StudioLoading), findsNothing);
      expect(recents.catalog.error, isNull);
      expect(tester.takeException(), isNull);
    });
  }
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final daysOld in [0, 2]) {
        testWidgets(
          'fresh group notification updates New answer before the Recents poll ${brightness.name} $scale age=$daysOld',
          (tester) async {
            tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            SharedPreferences.setMockInitialValues({});
            final preferences = await SharedPreferences.getInstance();
            final appPreferences = AppPreferences(preferences);
            final fixture = TechnicalSessionsFixture();
            final controller = ProfileWorkspaceController(
              access: ConnectionAccess(
                connection: identityTestConnection(),
                dashboardOAuth: null,
              ),
              connectionIdentity: 'group-arrival',
              preferences: preferences,
              appPreferences: appPreferences,
              gatewayFactory: fixture.gateway,
            );
            final host = BotsFixture();
            void answer(int sequence) => host.events.add({
              'room_id': 'room-1',
              'seq': sequence,
              'kind': 'message.member',
              'created_at':
                  fixture.now +
                  sequence -
                  (sequence == 1 ? daysOld * 86400 : 0),
              'actor': {'kind': 'member', 'id': 'atlas'},
              'payload': {'text': 'Group reply $sequence'},
            });
            answer(1);
            final bots = BotsSession((_) async => [host.repository]);
            final recents = WorkspaceRecentsSession(
              controller,
              bots,
              foreground: true,
            );
            final notices = ChatNotificationCoordinator(
              preferences,
              RecordingTurnNotificationSink(),
              appPreferences: appPreferences,
            );
            addTearDown(() async {
              await tester.pumpWidget(const SizedBox.shrink());
              recents.dispose();
              bots.dispose();
              controller.dispose();
              appPreferences.dispose();
            });
            await controller.initialize();
            await recents.refresh();
            final group = bots.observedGroups.single;
            await bots.groupReads.acknowledge(group, 1);
            final frame = GlobalKey();
            await tester.pumpWidget(
              MaterialApp(
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: RepaintBoundary(key: frame, child: child!),
                ),
                home: Scaffold(
                  body: WorkspaceActivityContent(
                    visible: true,
                    recents: recents,
                    onOpen: (_, _) {},
                    onOpenGroup: (_) async {},
                  ),
                ),
              ),
            );
            await tester.pump();
            final card = find.byKey(ValueKey('recent-group-${group.key}'));
            expect(card, daysOld == 0 ? findsOneWidget : findsNothing);
            expect(
              find.descendant(of: card, matching: find.text('New answer')),
              findsNothing,
            );
            answer(2);
            final release = Completer<void>();
            var refreshing = false;
            host.readHook = (_, method, _) async {
              if (method == 'groups.state') {
                refreshing = true;
                await release.future;
              }
              return null;
            };
            addTearDown(() {
              if (!release.isCompleted) release.complete();
            });
            host.observeGroupMessages();
            await notices.receiveGroupAnswer(
              GroupAnswerNotification(
                target: GroupNotificationTarget(group.scope, group.id),
                title: group.name,
                instance: group.instance,
                sequence: 2,
                text: 'Group reply 2',
              ),
            );
            for (var i = 0; i < 30; i++) {
              await tester.pump();
            }
            expect(
              find.descendant(of: card, matching: find.text('New answer')),
              findsOneWidget,
            );
            expect(
              recents.items().singleWhere((item) => item.group != null).unread,
              isTrue,
            );
            expect(bots.groupReads.sequence(group), 1);
            expect(
              refreshing,
              isFalse,
              reason: 'Observed messages need no follow-up read',
            );
            expect(find.text('Group reply 2'), findsOneWidget);
            await _captureRecents(
              tester,
              frame,
              'group-unread-held-${brightness.name}-$scale-age-$daysOld',
            );
            release.complete();
            for (var i = 0; i < 30; i++) {
              await tester.pump();
            }
            expect(find.text('Group reply 2'), findsOneWidget);
            expect(
              find.descendant(of: card, matching: find.text('New answer')),
              findsOneWidget,
            );
            await bots.groupReads.acknowledge(bots.observedGroups.single, 2);
            expect(bots.groupReads.unread(bots.observedGroups.single), isFalse);
            await tester.pump();
            expect(
              recents.items().singleWhere((item) => item.group != null).unread,
              isFalse,
            );
            await tester.pump();
            expect(
              find.descendant(of: card, matching: find.text('New answer')),
              findsNothing,
            );
            answer(3);
            host.readHook = (_, method, _) async {
              if (method == 'groups.log') {
                throw StateError('History unavailable');
              }
              return null;
            };
            host.observeGroupMessages();
            await notices.receiveGroupAnswer(
              GroupAnswerNotification(
                target: GroupNotificationTarget(group.scope, group.id),
                title: group.name,
                instance: group.instance,
                sequence: 3,
                text: 'Group reply 3',
              ),
            );
            for (var i = 0; i < 30; i++) {
              await tester.pump();
            }
            expect(
              find.descendant(of: card, matching: find.text('New answer')),
              findsOneWidget,
            );
            expect(bots.state.errors, isEmpty);
            expect(bots.groupReads.sequence(group), 2);
            host.readHook = null;
            answer(4);
            host.observeGroupMessages();
            await notices.receiveGroupAnswer(
              GroupAnswerNotification(
                target: GroupNotificationTarget(group.scope, group.id),
                title: group.name,
                instance: group.instance,
                sequence: 4,
                text: 'Group reply 4',
              ),
            );
            for (var i = 0; i < 30; i++) {
              await tester.pump();
            }
            expect(find.text('Group reply 4'), findsOneWidget);
            expect(
              find.descendant(of: card, matching: find.text('New answer')),
              findsOneWidget,
            );
            expect(bots.state.errors, isEmpty);
            expect(host.commands, isEmpty);
          },
        );
      }
    }
  }
  setUpAll(() async {
    if (!_captureLoading) return;
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
      'WingIcons': 'assets/fonts/wing-icons.ttf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(entry.value).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final cached in [false, true]) {
        testWidgets(
          '${cached ? 'usable Recents' : 'Recents initial loading'} has no layout jump ${brightness.name} $scale',
          (tester) async {
            tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            SharedPreferences.setMockInitialValues({});
            final preferences = await SharedPreferences.getInstance();
            final appPreferences = AppPreferences(preferences);
            final fixture = ProfileBrowserFixture();
            final controller = ProfileWorkspaceController(
              access: ConnectionAccess(
                connection: identityTestConnection(),
                dashboardOAuth: null,
              ),
              connectionIdentity: 'review',
              preferences: preferences,
              appPreferences: appPreferences,
              gatewayFactory: fixture.gateway,
            );
            var now = DateTime.now();
            final botFixture = BotsFixture();
            botFixture.events.add({
              'room_id': 'room-1',
              'seq': 1,
              'kind': 'message.member',
              'created_at': DateTime.now().millisecondsSinceEpoch / 1000,
              'actor': {'kind': 'member', 'id': 'atlas'},
              'payload': {'text': 'Saved group reply'},
            });
            final bots = BotsSession(
              (_) async => [botFixture.repository],
              now: () => now,
            );
            final recents = WorkspaceRecentsSession(
              controller,
              bots,
              foreground: true,
            );
            final release = Completer<void>(), started = Completer<void>();
            Future<void>? refresh;
            addTearDown(() {
              if (!release.isCompleted) release.complete();
              recents.dispose();
              bots.dispose();
              controller.dispose();
              appPreferences.dispose();
            });
            await controller.initialize();
            if (cached) await recents.refresh();
            final catalogRelease = Completer<void>();
            addTearDown(() {
              if (!catalogRelease.isCompleted) catalogRelease.complete();
            });
            botFixture.readHook = (_, method, _) async {
              if (method == 'groups.list' && !cached) {
                await catalogRelease.future;
              }
              if (method == 'session.active_list') {
                if (!started.isCompleted) started.complete();
                await release.future;
              }
              return null;
            };
            final frame = GlobalKey();
            var opens = 0;
            await tester.pumpWidget(
              MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: RepaintBoundary(key: frame, child: child!),
                ),
                home: Scaffold(
                  appBar: AppBar(
                    title: const Text('Recents'),
                    bottom: PreferredSize(
                      preferredSize: const Size.fromHeight(48),
                      child: Row(
                        children: const [
                          Expanded(child: Text('Instance')),
                          StudioLoadingSlot(),
                        ],
                      ),
                    ),
                  ),
                  body: WorkspaceActivityContent(
                    recents: recents,
                    visible: true,
                    onOpen: (_, _) => opens++,
                    onOpenGroup: (_) async => opens++,
                  ),
                ),
              ),
            );
            await tester.pump();
            final listPosition = tester.getTopLeft(find.byType(ListView));
            if (cached) {
              expect(recents.items(), isNotEmpty);
              expect(find.byType(StudioLoading), findsNothing);
              now = now.add(const Duration(seconds: 30));
              refresh = recents.refresh(force: true);
            } else {
              for (var i = 0; i < 20; i++) {
                await tester.pump();
              }
              expect(recents.items(), isEmpty);
              final progress = find.byType(StudioLoading);
              expect(progress, findsOneWidget);
              expect(
                find.ancestor(of: progress, matching: find.byType(AppBar)),
                findsOneWidget,
              );
              expect(
                tester.getRect(progress).bottom,
                lessThanOrEqualTo(listPosition.dy),
              );
              expect(
                tester.widget<StudioLoading>(progress).label,
                'Loading recent chats',
              );
              await _captureRecents(
                tester,
                frame,
                'initial-${brightness.name}-$scale',
              );
              refresh = recents.refresh();
              catalogRelease.complete();
            }
            for (var i = 0; i < 20; i++) {
              await tester.pump();
            }
            expect(started.isCompleted, isTrue);
            final readyPosition = tester.getTopLeft(
              find.byType(RecentIdentityCard).first,
            );
            expect(readyPosition.dy, greaterThanOrEqualTo(listPosition.dy));
            await tester.pump(const Duration(seconds: 11));
            expect(
              tester.getTopLeft(find.byType(RecentIdentityCard).first),
              readyPosition,
            );
            expect(controller.recentsLoading, isFalse);
            expect(bots.state.loading, isTrue);
            expect(find.text('Research team'), findsOneWidget);
            await _captureRecents(
              tester,
              frame,
              '${cached ? 'cached' : 'cold'}-ready-${brightness.name}-$scale',
            );
            await tester.tap(find.text('Research team'));
            await tester.pump();
            expect(
              opens,
              1,
              reason: 'Recents remains usable while background presence waits',
            );
            final loadingAfterElevenSeconds = find
                .byType(StudioLoading)
                .evaluate()
                .length;
            release.complete();
            for (var i = 0; i < 20; i++) {
              await tester.pump();
            }
            await refresh;
            expect(
              tester.getTopLeft(find.byType(RecentIdentityCard).first),
              readyPosition,
            );
            expect(bots.state.loading, isFalse);
            expect(
              find.byType(StudioLoading),
              findsNothing,
              reason: 'Completion clears the indicator',
            );
            await _captureRecents(
              tester,
              frame,
              '${cached ? 'cached' : 'cold'}-settled-${brightness.name}-$scale',
            );
            await tester.pumpWidget(const SizedBox.shrink());
            expect(
              loadingAfterElevenSeconds,
              cached ? 0 : 1,
              reason: cached
                  ? 'Automatic refresh of a completed catalog stays quiet'
                  : 'Initial entry pulses until presence and group reads settle',
            );
          },
        );
      }
    }
  }
  for (final failure in ['none', 'history', 'avatar']) {
    testWidgets(
      'Recents pulse spans partial chats and group history (failure=$failure)',
      (tester) async {
        final failHistory = failure == 'history';
        final failAvatar = failure == 'avatar';
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final appPreferences = AppPreferences(preferences);
        final fixture = TechnicalSessionsFixture();
        final controller = ProfileWorkspaceController(
          access: ConnectionAccess(
            connection: identityTestConnection(),
            dashboardOAuth: null,
          ),
          connectionIdentity: 'partial-loading',
          preferences: preferences,
          appPreferences: appPreferences,
          gatewayFactory: fixture.gateway,
        );
        final botFixture = BotsFixture();
        botFixture.profiles.first['has_avatar'] = true;
        botFixture.profiles.first['ui_meta']['hermes-bots']['imageKind'] =
            'photo';
        botFixture.events.add({
          'room_id': 'room-1',
          'seq': 1,
          'kind': 'message.member',
          'created_at': fixture.now,
          'actor': {'kind': 'member', 'id': 'atlas'},
          'payload': {'text': 'Last loaded reply'},
        });
        final catalogRelease = Completer<void>();
        final historyRelease = Completer<void>();
        final avatarRelease = Completer<void>();
        var avatarStarted = false;
        var historyStarted = false;
        botFixture.readHook = (_, method, _) async {
          if (method == 'profiles.get_asset') {
            avatarStarted = true;
            await avatarRelease.future;
            if (failAvatar) throw StateError('Avatar unavailable');
            return {
              'found': true,
              'data':
                  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aK7sAAAAASUVORK5CYII=',
            };
          }
          if (method == 'groups.list') await catalogRelease.future;
          if (method == 'groups.log') {
            historyStarted = true;
            await historyRelease.future;
            if (failHistory) throw StateError('History unavailable');
          }
          return null;
        };
        final bots = BotsSession((_) async => [botFixture.repository]);
        final recents = WorkspaceRecentsSession(
          controller,
          bots,
          foreground: true,
        );
        addTearDown(() {
          if (!catalogRelease.isCompleted) catalogRelease.complete();
          if (!historyRelease.isCompleted) historyRelease.complete();
          if (!avatarRelease.isCompleted) avatarRelease.complete();
          recents.dispose();
          bots.dispose();
          controller.dispose();
          appPreferences.dispose();
        });
        await controller.initialize();
        var opens = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              appBar: AppBar(actions: const [StudioLoadingSlot()]),
              body: WorkspaceActivityContent(
                recents: recents,
                visible: true,
                onOpen: (_, _) => opens++,
                onOpenGroup: (_) async {},
              ),
            ),
          ),
        );
        for (var i = 0; i < 20; i++) {
          await tester.pump();
        }
        final refresh = recents.refresh();
        expect(controller.recentsLoading, isFalse);
        expect(find.text('User conversation'), findsOneWidget);
        final cardPosition = tester.getTopLeft(
          find.byType(RecentIdentityCard).first,
        );
        final pulseDuringCatalog = find.byType(StudioLoading).evaluate().length;
        await tester.tap(find.text('User conversation'));
        await tester.pump();
        expect(opens, 1);
        catalogRelease.complete();
        for (var i = 0; i < 20; i++) {
          await tester.pump();
        }
        expect(historyStarted, isTrue);
        expect(find.text('Research team'), findsNothing);
        expect(
          tester.getTopLeft(find.byType(RecentIdentityCard).first),
          cardPosition,
        );
        final pulseDuringHistory = find.byType(StudioLoading).evaluate().length;
        historyRelease.complete();
        for (var i = 0; i < 20; i++) {
          await tester.pump();
        }
        expect(bots.state.loading, isFalse);
        expect(avatarStarted, isTrue);
        final pulseDuringAvatar = find.byType(StudioLoading).evaluate().length;
        avatarRelease.complete();
        for (var i = 0; i < 20; i++) {
          await tester.pump();
        }
        await refresh;
        expect(bots.warmAvatarCount, failAvatar ? 0 : 1);
        expect(find.byType(StudioLoading), findsNothing);
        expect(
          find.text('Research team'),
          failHistory ? findsNothing : findsOneWidget,
        );
        expect(bots.state.errors, failHistory ? isNotEmpty : isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(
          pulseDuringCatalog,
          1,
          reason: 'Partial chats do not complete Recents loading',
        );
        expect(
          pulseDuringAvatar,
          1,
          reason: 'Admitted avatar reads must settle too',
        );
        expect(
          pulseDuringHistory,
          1,
          reason: 'Group history must settle before the pulse stops',
        );
      },
    );
  }
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'production Recents waits for group logs ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          SharedPreferences.setMockInitialValues({});
          final preferences = await SharedPreferences.getInstance();
          final appPreferences = AppPreferences(preferences);
          final fixture = TechnicalSessionsFixture();
          final controller = ProfileWorkspaceController(
            access: ConnectionAccess(
              connection: identityTestConnection(),
              dashboardOAuth: null,
            ),
            connectionIdentity: 'route-loading',
            preferences: preferences,
            appPreferences: appPreferences,
            gatewayFactory: fixture.gateway,
          );
          final botFixture = BotsFixture();
          botFixture.events.add({
            'room_id': 'room-1',
            'seq': 1,
            'kind': 'message.member',
            'created_at': fixture.now,
            'actor': {'kind': 'member', 'id': 'atlas'},
            'payload': {
              'text':
                  'Last loaded reply. The research notes are ready, including the sources and the next steps for the team.',
            },
          });
          fixture.messagePreviewText =
              'I found three useful approaches. The first keeps the existing boundary and makes the workflow easier to maintain.';
          final release = Completer<void>();
          var historyStarted = false;
          botFixture.readHook = (_, method, _) async {
            if (method == 'groups.log') {
              historyStarted = true;
              await release.future;
            }
            return null;
          };
          addTearDown(() async {
            if (!release.isCompleted) release.complete();
            await tester.pumpWidget(const SizedBox.shrink());
            controller.dispose();
            appPreferences.dispose();
          });
          await controller.initialize();
          final frame = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(key: frame, child: child!),
              ),
              home: ProfileWorkspaceScreen(
                controller: controller,
                initialDestination: AppDestination.activity,
                createBotsSession: () =>
                    BotsSession((_) async => [botFixture.repository]),
              ),
            ),
          );
          for (var i = 0; i < 30; i++) {
            await tester.pump();
          }
          expect(historyStarted, isTrue);
          expect(find.text('User conversation'), findsOneWidget);
          expect(find.text('Research team'), findsNothing);
          expect(find.byType(StudioLoading), findsOneWidget);
          final title = tester.getRect(find.text('Recents'));
          final list = tester.getRect(find.byType(ListView).last);
          await _captureRecents(
            tester,
            frame,
            'route-held-${brightness.name}-$scale',
          );
          release.complete();
          for (var i = 0; i < 30; i++) {
            await tester.pump();
          }
          expect(find.text('Research team'), findsOneWidget);
          expect(find.byType(StudioLoading), findsNothing);
          expect(find.text(fixture.messagePreviewText), findsOneWidget);
          expect(
            find.text(
              'Last loaded reply. The research notes are ready, including the sources and the next steps for the team.',
            ),
            findsOneWidget,
          );
          expect(tester.getRect(find.text('Recents')), title);
          expect(tester.getRect(find.byType(ListView).last), list);
          await _captureRecents(
            tester,
            frame,
            'route-settled-${brightness.name}-$scale',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final failWarmUp in [false, true]) {
    testWidgets(
      'Recents warm-up respects readiness and foreground without hidden polling (failure=$failWarmUp)',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final appPreferences = AppPreferences(preferences);
        final fixture = TechnicalSessionsFixture();
        final controller = ProfileWorkspaceController(
          access: ConnectionAccess(
            connection: identityTestConnection(),
            dashboardOAuth: null,
          ),
          connectionIdentity: 'deferred-warm-up',
          preferences: preferences,
          appPreferences: appPreferences,
          gatewayFactory: fixture.gateway,
        );
        final bots = BotsSession((_) async => const []);
        final recents = WorkspaceRecentsSession(
          controller,
          bots,
          foreground: true,
        );
        addTearDown(() {
          recents.dispose();
          bots.dispose();
          controller.dispose();
          appPreferences.dispose();
        });
        recents.warmUp();
        await tester.pump();
        expect(
          fixture.reads,
          isEmpty,
          reason: 'Wait for workspace initialization',
        );
        recents.setForeground(false);
        await controller.initialize();
        final startupReads = fixture.reads.length;
        await tester.pump();
        expect(fixture.reads.length, startupReads);
        expect(controller.recentsLoaded, isFalse);
        fixture.failHistory = failWarmUp;
        recents.setForeground(true);
        for (var i = 0; i < 30; i++) {
          await tester.pump();
        }
        expect(controller.recentsLoaded, isTrue);
        expect(recents.contentLoading, isFalse);
        expect(recents.catalog.error, failWarmUp ? isNotNull : isNull);
        final preparedReads = fixture.reads.length;
        recents.warmUp();
        recents.setForeground(false);
        recents.setForeground(true);
        await tester.pump(const Duration(minutes: 2));
        expect(
          fixture.reads.length,
          preparedReads,
          reason: 'Startup warm-up does not admit polling or repeat on resume',
        );
        fixture.failHistory = false;
        await recents.refresh(force: true);
        expect(recents.catalog.error, isNull);
        expect(recents.items(), isNotEmpty);
        expect(fixture.reads.length, greaterThan(preparedReads));
      },
    );
  }

  for (final enterWhileLoading in [false, true]) {
    testWidgets(
      'startup warms Recents before navigation (pending=$enterWhileLoading)',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final appPreferences = AppPreferences(preferences);
        final fixture = TechnicalSessionsFixture();
        final controller = ProfileWorkspaceController(
          access: ConnectionAccess(
            connection: identityTestConnection(),
            dashboardOAuth: null,
          ),
          connectionIdentity: 'startup-recents',
          preferences: preferences,
          appPreferences: appPreferences,
          gatewayFactory: fixture.gateway,
        );
        final botFixture = BotsFixture();
        botFixture.events.add({
          'room_id': 'room-1',
          'seq': 1,
          'kind': 'message.member',
          'created_at': fixture.now,
          'actor': {'kind': 'member', 'id': 'atlas'},
          'payload': {'text': 'Warm group preview'},
        });
        final release = Completer<void>();
        var historyReads = 0;
        botFixture.readHook = (_, method, _) async {
          if (method == 'groups.log') {
            historyReads++;
            await release.future;
          }
          return null;
        };
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          await tester.pumpWidget(const SizedBox.shrink());
          controller.dispose();
          appPreferences.dispose();
        });
        final frame = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(Brightness.light),
            home: RepaintBoundary(
              key: frame,
              child: ProfileWorkspaceScreen(
                controller: controller,
                createBotsSession: () =>
                    BotsSession((_) async => [botFixture.repository]),
              ),
            ),
          ),
        );
        for (var i = 0; i < 30; i++) {
          await tester.pump();
        }
        expect(controller.initialized, isTrue);
        expect(find.byType(WorkspaceActivityContent), findsNothing);
        expect(
          historyReads,
          1,
          reason: 'Warm the shared catalog before opening Recents',
        );
        expect(
          find.byType(StudioLoading),
          findsNothing,
          reason: 'Automatic preparation must leave Chats usable and quiet',
        );
        if (!enterWhileLoading) {
          release.complete();
          for (var i = 0; i < 30; i++) {
            await tester.pump();
          }
        }
        final chatReads = fixture.reads.length;
        await tester.tap(find.byTooltip('Open navigation menu'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('nav-activity')));
        await tester.pump();
        expect(find.byType(WorkspaceActivityContent), findsOneWidget);
        expect(find.text('User conversation'), findsOneWidget);
        // The shared header publishes sibling loading registrations after build.
        await tester.pump();
        expect(
          find.byType(StudioLoading),
          enterWhileLoading ? findsOneWidget : findsNothing,
        );
        await _captureRecents(
          tester,
          frame,
          'startup-entry-$enterWhileLoading',
        );
        if (enterWhileLoading) {
          release.complete();
        }
        await tester.pumpAndSettle();
        expect(find.text('Research team'), findsOneWidget);
        expect(find.text('Warm group preview'), findsOneWidget);
        expect(find.byType(StudioLoading), findsNothing);
        expect(
          historyReads,
          1,
          reason: 'Navigation joins or reuses startup preparation',
        );
        expect(
          fixture.reads.length,
          chatReads,
          reason: 'Navigation must also reuse the prepared chat catalog',
        );
        await _captureRecents(tester, frame, 'startup-warm-$enterWhileLoading');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('empty Recents settles loading without replacing its catalog', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final appPreferences = AppPreferences(preferences);
    final fixture = ProfileBrowserFixture();
    final controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'empty-loading',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: fixture.gateway,
    );
    final release = Completer<void>();
    final bots = BotsSession((_) async {
      await release.future;
      return const [];
    });
    final recents = WorkspaceRecentsSession(controller, bots, foreground: true);
    addTearDown(() {
      if (!release.isCompleted) release.complete();
      recents.dispose();
      bots.dispose();
      controller.dispose();
      appPreferences.dispose();
    });
    await controller.initialize();
    await controller.refreshRecents();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(actions: const [StudioLoadingSlot()]),
          body: WorkspaceActivityContent(
            recents: recents,
            visible: false,
            onOpen: (_, _) {},
            onOpenGroup: (_) async {},
          ),
        ),
      ),
    );
    final catalog = recents.catalog;
    expect(recents.items(), isEmpty);
    expect(find.text('No recent chats'), findsNothing);
    final refresh = bots.refresh();
    for (var i = 0; i < 20; i++) {
      await tester.pump();
    }
    expect(recents.contentLoading, isTrue);
    expect(find.byType(StudioLoading), findsOneWidget);
    expect(find.text('No recent chats'), findsNothing);
    release.complete();
    for (var i = 0; i < 20; i++) {
      await tester.pump();
    }
    await refresh;
    expect(recents.catalog, same(catalog));
    expect(recents.contentLoading, isFalse);
    expect(find.byType(StudioLoading), findsNothing);
    expect(find.text('No recent chats'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  test('Recents excludes the observed oneshot technical run', () async {
    SharedPreferences.setMockInitialValues({});
    final fixture = TechnicalSessionsFixture();
    final preferences = await SharedPreferences.getInstance();
    final appPreferences = AppPreferences(preferences);
    addTearDown(appPreferences.dispose);
    final controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'technical-recents',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: fixture.gateway,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.refreshRecents();
    expect(controller.recentChats().map((chat) => chat.key.sessionId), [
      'user-chat',
    ]);
  });
  for (final running in [false, true]) {
    test('Recents excludes a loaded oneshot run (running=$running)', () async {
      SharedPreferences.setMockInitialValues({});
      final fixture = TechnicalSessionsFixture();
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: identityTestConnection(),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'loaded-technical',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: fixture.gateway,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final resource = controller.current!;
      final chat = await openFixtureChat(
        controller: controller,
        key: ProfileSessionKey(resource.scope, 'technical-run'),
        title: 'Technical command',
        select: false,
      );
      chat.reading.installSavedHistory([
        ...chat.reading.messages,
        {'role': 'assistant', 'content': 'Result', 'timestamp': fixture.now},
      ]);
      if (running) emitChatEvent(controller, chat, 'message.start');

      expect(controller.recentChats(), isEmpty);
    });
  }
  test(
    'Recents excludes a remote live oneshot run with old messages',
    () async {
      SharedPreferences.setMockInitialValues({});
      final fixture = TechnicalSessionsFixture()..oldTechnicalHistory = true;
      fixture.liveSessions['personal'] = [
        {
          'id': 'technical-runtime',
          'session_key': 'technical-run',
          'status': 'working',
          'last_active': fixture.now,
        },
      ];
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: identityTestConnection(),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'live-technical',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: fixture.gateway,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.refreshRecents();
      expect(controller.recentChats().map((chat) => chat.key.sessionId), [
        'user-chat',
      ]);
    },
  );

  for (final source in ['cron', 'tool', 'subagent', 'kanban', 'oneshot']) {
    test(
      'Recents hides $source even with Show automated chats enabled',
      () async {
        SharedPreferences.setMockInitialValues({});
        final fixture = TechnicalSessionsFixture()..technicalSource = source;
        fixture.liveSessions['personal'] = [
          {
            'id': 'technical-runtime',
            'session_key': 'technical-run',
            'status': 'waiting',
            'last_active': fixture.now,
          },
        ];
        final preferences = await SharedPreferences.getInstance();
        final appPreferences = AppPreferences(preferences);
        addTearDown(appPreferences.dispose);
        final controller = ProfileWorkspaceController(
          access: ConnectionAccess(
            connection: identityTestConnection(),
            dashboardOAuth: null,
          ),
          connectionIdentity: 'automation-$source',
          preferences: preferences,
          appPreferences: appPreferences,
          gatewayFactory: fixture.gateway,
        );
        addTearDown(controller.dispose);
        await controller.initialize();
        await controller.setSessionVisibility(SessionVisibility.all);
        await controller.refreshRecents();
        expect(controller.liveActivity.single.source, source);
        expect(controller.recentChats().map((chat) => chat.key.sessionId), [
          'user-chat',
        ]);
        expect(
          fixture.reads.where(
            (read) => read.$1 == 'sessions/technical-run/messages',
          ),
          isEmpty,
        );
      },
    );
  }

  test(
    'Recents keeps interactive and custom sources, branches and parent background work',
    () async {
      SharedPreferences.setMockInitialValues({});
      final fixture = TechnicalSessionsFixture();
      for (final source in ['cli', 'telegram', 'custom', 'unknown', null]) {
        fixture.extraRows.add({
          'id': 'chat-$source',
          'title': 'Conversation',
          'source': source,
          'profile': 'personal',
          'last_active': fixture.now - 60,
          'parent_session_id': 'user-chat',
        });
      }
      fixture.liveSessions['personal'] = [
        {
          'id': 'user-runtime',
          'session_key': 'user-chat',
          'status': 'idle',
          'side_tasks_running': 2,
          'last_active': fixture.now,
        },
      ];
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: identityTestConnection(),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'user-sources',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: fixture.gateway,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.refreshRecents();
      expect(
        controller.recentChats().map((chat) => chat.key.sessionId),
        unorderedEquals([
          'user-chat',
          'chat-cli',
          'chat-telegram',
          'chat-custom',
          'chat-unknown',
          'chat-null',
        ]),
      );
      expect(
        controller
            .recentChats()
            .singleWhere((chat) => chat.key.sessionId == 'user-chat')
            .sideTasksRunning,
        2,
      );
    },
  );

  test(
    'a full page of internal sessions does not hide later recent chats',
    () async {
      SharedPreferences.setMockInitialValues({});
      final fixture = TechnicalSessionsFixture();
      fixture.extraRows.addAll([
        for (var i = 0; i < 100; i++)
          {
            'id': 'internal-$i',
            'title': 'Internal',
            'source': 'oneshot',
            'profile': 'personal',
            'last_active': fixture.now,
          },
      ]);
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: identityTestConnection(),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'internal-page',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: fixture.gateway,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.refreshRecents();
      expect(controller.recentChats().map((chat) => chat.key.sessionId), [
        'user-chat',
      ]);
      expect(
        fixture.reads.any(
          (read) => read.$1 == 'sessions' && read.$2['offset'] == '100',
        ),
        isTrue,
      );
    },
  );
}
