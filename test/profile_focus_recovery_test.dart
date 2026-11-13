import 'dart:convert';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/bots_session.dart';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/services/ws_client.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/widgets/app_drawer.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/recent_identity_card.dart';
import 'package:wing/core/widgets/studio_loading.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'profile_workspace_controller_test.dart' show Host;

const _captureRecovery = bool.fromEnvironment('CAPTURE_CONNECTION_RECOVERY');

void main() {
  late Host host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ProfileChat chat;
  final navigator = GlobalKey<NavigatorState>();

  setUpAll(() async {
    // Use the production font metrics for enlarged recovery messages in every
    // run; Ahem's square glyphs make the ordinary Retry control unreachable.
    final configFile = File('.dart_tool/package_config.json');
    final config =
        jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
    final flutter = (config['packages'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((entry) => entry['name'] == 'flutter');
    final root = Directory.fromUri(
      configFile.uri.resolve(flutter['rootUri'] as String),
    );
    final fonts = root.parent.parent.uri.resolve(
      'bin/cache/artifacts/material_fonts/',
    );
    for (final entry in {
      'Roboto': fonts.resolve('Roboto-Regular.ttf'),
      'MaterialIcons': fonts.resolve('MaterialIcons-Regular.otf'),
      'WingIcons': File('assets/fonts/wing-icons.ttf').absolute.uri,
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File.fromUri(entry.value).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    host = Host()..running = false;
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'focus-recovery',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
    chat = await controller.createChat(canDispatch: () => true);
    await controller.updateDraft(chat, 'Keep my draft');
  });
  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  test(
    'background HTTP failure leaves a healthy chat out of recovery',
    () async {
      final status = controller.connectionStatus;
      expect(status.live, ConnectionAvailability.available);
      final connects = host.connectCalls;
      final disconnects = host.disconnectCalls;
      await expectLater(
        status.observeAccess(() async {
          throw http.ClientException('Background session read failed');
        }),
        throwsA(isA<http.ClientException>()),
      );
      expect(status.phase, ServerConnectionPhase.limited);
      expect(controller.current!.reconnectScheduled, isFalse);
      expect(controller.recovering, isFalse);
      expect(host.connectCalls, connects);
      expect(host.disconnectCalls, disconnects);
      status.accessAvailable();
      expect(status.phase, ServerConnectionPhase.connected);
      controller.networkUnavailable();
      // Fork (Wing Voice): Q7=A network gate
      // probe moved: upstream API rename 894b389e
      expect(controller.current!.reconnectScheduled, isFalse);
      final attempts = host.connectCalls; // probe moved: upstream API rename 894b389e
      controller.networkRestored(); // probe moved: upstream API rename 894b389e
      await controller.resumeConnection(networkChanged: true); // probe moved: upstream API rename 894b389e
      expect(host.connectCalls, greaterThan(attempts)); // probe moved: upstream API rename 894b389e
      expect(host.disconnectCalls, greaterThan(disconnects));
    },
  );

  test('network route changes preserve a responsive live connection', () async {
    final connects = host.connectCalls;
    final disconnects = host.disconnectCalls;
    final phases = <ServerConnectionPhase>[];
    controller.connectionStatus.addListener(
      () => phases.add(controller.connectionStatus.phase),
    );
    for (var change = 0; change < 3; change++) {
      await controller.resumeConnection(networkChanged: true);
    }
    expect(host.connectCalls, connects);
    expect(host.disconnectCalls, disconnects);
    expect(phases, everyElement(ServerConnectionPhase.connected));
    expect(controller.recovering, isFalse);
    expect(chat.composer.observation.text, 'Keep my draft');
  });

  for (final failed in [false, true]) {
    test(
      'network change during recovery awaits ${failed ? 'failed' : 'successful'} replacement',
      () async {
        final history = Completer<void>();
        host.heldHistoryStarted = Completer<void>();
        host.heldHistoryDelay = history;
        final calls = host.connectCalls;
        final recovery = controller.reconnect(chat.key.workspace);
        await host.heldHistoryStarted!.future;

        host.activeListDelay = Completer<void>();
        final networkRecovery = controller.resumeConnection(
          networkChanged: true,
        );
        final refresh = controller.refreshActivity();
        await Future<void>.delayed(Duration.zero);
        if (failed) {
          host.connectError = StateError('Replacement connection failed');
        }
        host.activeListDelay!.completeError(
          JsonRpcError(
            'session.active_list',
            'Old route stopped responding',
            reason: 'request_timeout',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        host.activeListDelay = null;
        history.complete();
        await Future.wait([recovery, networkRecovery, refresh]);

        expect(
          controller.activityProfileErrors,
          failed ? {'server': 'Live status could not be loaded.'} : isEmpty,
          reason:
              'Recents must not report Live status could not be loaded. '
              'after an overlapping network recovery.',
        );
        expect(controller.connectionStatus.liveAvailable('a'), !failed);
        expect(host.connectCalls, calls + 2);
        expect(chat.composer.observation.text, 'Keep my draft');
        expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
      },
    );
  }

  for (final failed in [false, true]) {
    test(
      'activity refresh waits for ${failed ? 'failed' : 'successful'} recovery',
      () async {
        final connection = Completer<void>();
        host.connectDelay = connection;
        if (failed) host.connectError = StateError('Recovery failed');
        final calls = host.connectCalls;
        final activeReads = host.calls
            .where((call) => call.$2 == 'session.active_list')
            .length;
        final recovery = controller.reconnect(chat.key.workspace);
        var refreshed = false;
        final refresh = controller.refreshActivity().then(
          (_) => refreshed = true,
        );
        await Future<void>.delayed(Duration.zero);

        expect(host.connectCalls, calls + 1);
        expect(refreshed, isFalse);
        expect(
          host.calls.where((call) => call.$2 == 'session.active_list'),
          hasLength(activeReads),
        );

        connection.complete();
        await Future.wait([recovery, refresh]);
        expect(host.connectCalls, calls + 1);
        expect(controller.connectionStatus.liveAvailable('a'), !failed);
        expect(
          host.calls.where((call) => call.$2 == 'session.active_list'),
          hasLength(activeReads + (failed ? 0 : 1)),
        );
        expect(controller.activityProfileErrors.isNotEmpty, failed);
        expect(chat.composer.observation.text, 'Keep my draft');
        expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
      },
    );
  }

  Future<void> render(
    WidgetTester tester, {
    AppDestination destination = AppDestination.chats,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
          initialDestination: destination,
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }

  Future<void> settleRecovery(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }

  void select(WidgetTester tester, AppDestination destination) {
    final drawer = tester.widget<Scaffold>(find.byType(Scaffold).first).drawer;
    if (drawer is! AppDrawer) throw StateError('Workspace drawer missing');
    drawer.onSelected(destination);
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'Recents held recovery keeps cards ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          host.profiles = ['a'];
          host.indexedSessions = [
            {
              'id': 'same',
              'profile': 'a',
              'title': 'Saved recent conversation',
              'source': 'desktop',
              'last_active': DateTime.now().millisecondsSinceEpoch / 1000,
            },
          ];
          host.historyMessages = [
            {
              'id': 1,
              'role': 'assistant',
              'content': 'Saved reply',
              'timestamp': DateTime.now().millisecondsSinceEpoch / 1000,
            },
          ];
          await controller.refreshRecents();
          expect(
            controller.recentChats(),
            isNotEmpty,
            reason: '${controller.recentsProfileErrors} ${host.reads}',
          );
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
                createBotsSession: () => BotsSession((_) async => []),
              ),
            ),
          );
          await settleRecovery(tester);
          final cards = find.byType(RecentIdentityCard);
          expect(cards, findsWidgets);
          expect(find.byType(StudioLoading), findsNothing);
          final rectangles = [
            for (final card in cards.evaluate())
              tester.getRect(find.byWidget(card.widget)),
          ];
          final title = tester.getRect(find.text('Recents'));
          final connection = Completer<void>();
          host.connectDelay = connection;
          addTearDown(() {
            if (!connection.isCompleted) connection.complete();
          });
          final recovery = controller.reconnect(chat.key.workspace);
          final connectionCalls = host.connectCalls;
          await tester.pump();
          await tester.pump();
          expect(find.byType(StudioLoading), findsOneWidget);
          await tester.pump(const Duration(seconds: 12));
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(find.textContaining('Reconnecting'), findsNothing);
          expect(find.textContaining('Your draft stays here'), findsNothing);
          for (final card in tester.widgetList<RecentIdentityCard>(cards)) {
            expect(card.onTap, isNotNull);
          }
          expect(host.connectCalls, connectionCalls);
          expect(tester.getRect(find.text('Recents')), title);
          expect([
            for (final card in cards.evaluate())
              tester.getRect(find.byWidget(card.widget)),
          ], rectangles);
          expect(chat.composer.observation.text, 'Keep my draft');
          expect(tester.takeException(), isNull);

          Future<void> capture(String state) async {
            if (!_captureRecovery) return;
            await tester.runAsync(() async {
              final boundary =
                  frame.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final bitmap = await boundary.toImage();
              try {
                final bytes = await bitmap.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final directory = Directory(
                  'build/design-previews/connection-recovery',
                )..createSync(recursive: true);
                await File(
                  '${directory.path}/${brightness.name}-$scale-$state.png',
                ).writeAsBytes(bytes!.buffer.asUint8List());
              } finally {
                bitmap.dispose();
              }
            });
          }

          await capture('held');
          connection.complete();
          var recovered = false;
          unawaited(recovery.then((_) => recovered = true));
          for (var attempt = 0; attempt < 100 && !recovered; attempt++) {
            await settleRecovery(tester);
          }
          expect(recovered, isTrue);
          await tester.pump();
          expect(find.byType(StudioLoading), findsNothing);
          expect(tester.getRect(find.text('Recents')), title);
          expect([
            for (final card in cards.evaluate())
              tester.getRect(find.byWidget(card.widget)),
          ], rectangles);
          expect(chat.composer.observation.text, 'Keep my draft');
          expect(
            host.calls.where((call) => call.$2 == 'prompt.submit'),
            isEmpty,
          );
          await capture('settled');
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'pending chat Retry shows recovery through history ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final preferences = await SharedPreferences.getInstance();
          await preferences.setStringList('profile_pending_v2_focus-recovery', [
            jsonEncode(chat.key.toJson()),
          ]);
          final access = controller.access;
          controller.dispose();
          host.resumeError = JsonRpcError(
            'session.resume',
            'session not found',
            code: 4007,
          );
          controller = ProfileWorkspaceController(
            access: access,
            connectionIdentity: 'focus-recovery',
            preferences: preferences,
            appPreferences: appPreferences,
            gatewayFactory: host.gateway,
          );
          await controller.initialize();
          final frame = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: scale == 2,
                ),
                child: RepaintBoundary(key: frame, child: child!),
              ),
              home: ProfileWorkspaceScreen(
                initialDestination: AppDestination.activity,
                controller: controller,
                createBotsSession: () => BotsSession((_) async => []),
              ),
            ),
          );
          await settleRecovery(tester);
          expect(controller.error, isNotNull);
          final resume = Completer<void>();
          final history = Completer<void>();
          addTearDown(() {
            if (!resume.isCompleted) resume.complete();
            if (!history.isCompleted) history.complete();
          });
          host
            ..resumeError = null
            ..resumeStarted = Completer<void>()
            ..resumeDelay = resume
            ..heldHistoryStarted = Completer<void>()
            ..heldHistoryDelay = history;
          await tester.tap(find.text('Retry').first);
          await tester.pump();
          await tester.pump();
          expect(find.byType(StudioLoading), findsOneWidget);
          await host.resumeStarted!.future;
          resume.complete();
          await settleRecovery(tester);
          await host.heldHistoryStarted!.future;
          expect(find.byType(StudioLoading), findsOneWidget);
          if (_captureRecovery) {
            await tester.runAsync(() async {
              final boundary =
                  frame.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final bitmap = await boundary.toImage();
              final bytes = await bitmap.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final directory = Directory(
                'build/design-previews/connection-recovery',
              )..createSync(recursive: true);
              await File(
                '${directory.path}/pending-${brightness.name}-$scale.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
              bitmap.dispose();
            });
          }
          history.complete();
          for (
            var attempt = 0;
            attempt < 30 && controller.recovering;
            attempt++
          ) {
            await settleRecovery(tester);
          }
          await tester.pump();
          expect(find.byType(StudioLoading), findsNothing);
          expect(controller.error, isNull);
          expect(
            preferences.getStringList('profile_pending_v2_focus-recovery'),
            isEmpty,
          );
          expect(
            host.calls.where((call) => call.$2 == 'prompt.submit'),
            isEmpty,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets('app resume immediately retries the visible chat', (
    tester,
  ) async {
    await render(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    host.connectError = TimeoutException('Network asleep');
    await controller.resumeConnection();
    final calls = host.connectCalls;
    host.connectError = null;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settleRecovery(tester);
    expect(host.connectCalls, calls + 1);
    expect(controller.recovering, isFalse);
    expect(chat.composer.observation.text, 'Keep my draft');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final destination in [
    AppDestination.activity,
    AppDestination.settings,
  ]) {
    testWidgets('app resume reconnects from ${destination.label}', (
      tester,
    ) async {
      await render(tester);
      select(tester, destination);
      await settleRecovery(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      host.connectError = TimeoutException('Network asleep');
      host.gateways['a']!.onConnectionChanged!(false);
      for (final seconds in [1, 2, 4, 8, 16]) {
        await tester.pump(Duration(seconds: seconds));
      }
      expect(controller.current!.reconnectScheduled, isTrue);
      expect(controller.connectionStatus.liveAvailable('a'), isFalse);
      final calls = host.connectCalls;
      host.connectError = null;

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settleRecovery(tester);

      expect(host.connectCalls, calls + 1);
      expect(controller.connectionStatus.liveAvailable('a'), isTrue);
      expect(controller.recovering, isFalse);
      expect(controller.visible, isFalse);
      expect(chat.composer.observation.text, 'Keep my draft');
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('opening Activity retries a retained disconnected workspace', (
    tester,
  ) async {
    host.connectError = TimeoutException('Network asleep');
    await controller.resumeConnection();
    final resumes = host.calls
        .where((call) => call.$2 == 'session.resume')
        .length;
    host.connectError = null;

    await render(tester, destination: AppDestination.activity);
    await settleRecovery(tester);

    expect(
      host.calls.where((call) => call.$2 == 'session.resume'),
      hasLength(resumes + 1),
    );
    expect(controller.recovering, isFalse);
    expect(controller.visible, isFalse);
    expect(chat.composer.observation.text, 'Keep my draft');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('opening App settings retries before the scheduled timer', (
    tester,
  ) async {
    await render(tester);
    host.connectError = TimeoutException('Network asleep');
    await controller.resumeConnection();
    final calls = host.connectCalls;
    host.connectError = null;

    select(tester, AppDestination.settings);
    await settleRecovery(tester);

    expect(host.connectCalls, calls + 1);
    expect(controller.recovering, isFalse);
    expect(controller.visible, isFalse);
    expect(chat.composer.observation.text, 'Keep my draft');
    expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a covered chat waits until navigation returns to it', (
    tester,
  ) async {
    await render(tester);
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('Other page')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.visible, isFalse);
    host.connectError = TimeoutException('Network asleep');
    await controller.resumeConnection();
    final calls = host.connectCalls;
    host.connectError = null;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(host.connectCalls, calls);

    navigator.currentState!.pop();
    await settleRecovery(tester);
    expect(host.connectCalls, calls + 1);
    expect(controller.recovering, isFalse);
    expect(controller.visible, isTrue);
    expect(chat.composer.observation.text, 'Keep my draft');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('repeated focus events share an in-flight recovery', (
    tester,
  ) async {
    await render(tester);
    final history = Completer<void>();
    host.delays['a'] = history;
    host.gateways['a']!.onConnectionChanged!(false);
    final before = host.connectCalls;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(host.connectCalls, before + 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(host.connectCalls, before + 1);
    history.complete();
    await settleRecovery(tester);
    expect(controller.recovering, isFalse);
    expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('returning to a connected screen leaves its connection alone', (
    tester,
  ) async {
    await render(tester);
    final calls = host.connectCalls;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settleRecovery(tester);
    expect(host.connectCalls, calls);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('returning to Chats retries before the scheduled timer', (
    tester,
  ) async {
    await render(tester);
    select(tester, AppDestination.activity);
    await tester.pumpAndSettle();
    host.connectError = TimeoutException('Network asleep');
    await controller.resumeConnection();
    final calls = host.connectCalls;
    host.connectError = null;
    select(tester, AppDestination.chats);
    await settleRecovery(tester);
    expect(host.connectCalls, calls + 1);
    expect(controller.recovering, isFalse);
    expect(chat.composer.observation.text, 'Keep my draft');
    expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
