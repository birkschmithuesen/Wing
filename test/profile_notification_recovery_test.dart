import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/composer_action.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/composer_action_button.dart';
import 'package:wing/core/widgets/studio_loading.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'profile_workspace_controller_test.dart' show Host;

class _ResumeHost extends Host {
  Map<String, dynamic>? resumeInfo;
  bool failResumeOnce = false;
  int resumeCalls = 0;

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: base.discover,
      connect: base.connect,
      get: base.read,
      rpc: (method, params) async {
        if (method == 'session.resume') {
          resumeCalls++;
          await resumeDelay?.future;
          if (resumeError case final failure?) {
            if (failResumeOnce) resumeError = null;
            throw failure;
          }
        }
        final result = await base.call(method, params);
        return method == 'session.resume' && resumeInfo != null
            ? {...result, 'info': resumeInfo}
            : result;
      },
    );
  }
}

void main() {
  late _ResumeHost host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ProfileChat chat;

  final retry = find.descendant(
    of: find.byType(MaterialBanner),
    matching: find.byTooltip('Retry'),
  );

  Future<void> until(
    WidgetTester tester,
    bool Function() ready,
    String outcome,
  ) async {
    await tester.pump();
    expect(tester.takeException(), isNull);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!ready() && DateTime.now().isBefore(deadline)) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.takeException(), isNull);
    }
    expect(ready(), isTrue, reason: outcome);
  }

  const capture = bool.fromEnvironment('CAPTURE_RECOVERY');
  setUpAll(() async {
    if (!capture) return;
    const dir = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final font in {
      'Roboto': '$dir/Roboto-Regular.ttf',
      'MaterialIcons': '$dir/MaterialIcons-Regular.otf',
      'WingIcons': 'assets/fonts/wing-icons.ttf',
    }.entries) {
      await (FontLoader(
            font.key,
          )..addFont(File(font.value).readAsBytes().then(ByteData.sublistView)))
          .load();
    }
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    host = _ResumeHost()..running = false;
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'notification-recovery',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
    chat = await controller.createChat(canDispatch: () => true);
    await controller.updateDraft(chat, 'My unsent follow-up');
  });
  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  // Canonical local snapshots echo their profile even before agent creation;
  // non-local snapshots may carry only the protocol identity.
  for (final info in [
    {'desktop_protocol': 'hermes-gateway-v1'},
    {
      'desktop_protocol': 'hermes-gateway-v1',
      'profile_name': 'a',
      'lazy': true,
    },
  ]) {
    testWidgets(
      'notification opens the canonical ${info.containsKey('profile_name') ? 'local lazy' : 'minimal non-local'} snapshot',
      (tester) async {
        host.resumeInfo = info;
        await controller.openNotification(chat.key);
        await tester.pumpWidget(
          MaterialApp(
            home: ProfileWorkspaceScreen(
              createBotsSession: () => BotsSession((_) async => const []),
              controller: controller,
            ),
          ),
        );
        await tester.pump();

        expect(chat.runtime.openingError, isNull);
        expect(chat.runtime.opening, isFalse);
        expect(controller.notificationChat, isNull);
        expect(controller.current!.chat, same(chat));
        expect(chat.composer.observation.text, 'My unsent follow-up');
        expect(retry, findsNothing);
        expect(
          host.calls
              .where((call) => call.$2 == 'session.resume')
              .single
              .$3['profile'],
          chat.key.workspace.profileName,
        );
        expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final info in [
    {'lazy': true, 'profile_name': 'another-profile'},
    {'lazy': true, 'profile_name': null},
    {'profile_name': 17},
  ]) {
    test(
      'rejects invalid or conflicting session owner metadata: $info',
      () async {
        host.resumeInfo = info;
        await expectLater(
          controller.current!.gateway.resume(chat.key.sessionId),
          throwsFormatException,
        );
      },
    );
  }

  test(
    'successful notification recovery publishes the ready composer state',
    () async {
      final observed = <({bool opening, bool notification})>[];
      controller.addListener(() {
        observed.add((
          opening: chat.runtime.opening,
          notification: controller.notificationChat != null,
        ));
      });
      await controller.openNotification(chat.key);
      expect(chat.runtime.opening, isFalse);
      expect(observed.last, (opening: false, notification: false));
    },
  );

  testWidgets('leaving a failed notification cancels its background retries', (
    tester,
  ) async {
    host.resumeError = TimeoutException('Synthetic outage');
    await controller.openNotification(chat.key);
    controller.showList();
    await tester.pump(const Duration(minutes: 2));
    expect(host.resumeCalls, 1);
    expect(controller.notificationChat, isNull);
    expect(chat.composer.observation.text, 'My unsent follow-up');
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('failed recovery layout ${brightness.name} $scale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(360, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        host.resumeError = JsonRpcError(
          'session.resume',
          'Invalid parameters',
          code: 4000,
        );
        await controller.openNotification(chat.key);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: wingTheme(brightness),
            builder: (context, child) => RepaintBoundary(
              key: boundary,
              child: MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  viewInsets: const EdgeInsets.only(bottom: 260),
                ),
                child: child!,
              ),
            ),
            home: ProfileWorkspaceScreen(
              createBotsSession: () => BotsSession((_) async => const []),
              controller: controller,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(retry.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (capture) {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await render.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/recovery-review/${brightness.name}-$scale.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets(
    'cached notification failure stores Send and preserves a fresh draft on retry',
    (tester) async {
      host.resumeError = JsonRpcError(
        'session.resume',
        'Invalid parameters',
        code: 4000,
      );
      await controller.openNotification(chat.key);
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileWorkspaceScreen(
            createBotsSession: () => BotsSession((_) async => const []),
            controller: controller,
          ),
        ),
      );
      await tester.pump();
      expect(chat.runtime.openingError, isNotNull);
      expect(chat.reading.messages.single['content'], 'a completed');
      expect(retry, findsOneWidget);
      expect(
        controller.connectionStatus.phase,
        ServerConnectionPhase.disconnected,
      );
      // Healthy unrelated reads must not hide the failed conversation recovery.
      controller.connectionStatus.accessAvailable();
      expect(
        controller.connectionStatus.phase,
        ServerConnectionPhase.disconnected,
      );
      expect(
        tester
            .widget<ComposerActionButton>(find.byType(ComposerActionButton))
            .unavailable[ComposerAction.send],
        isNull,
      );
      final send = find.byType(ComposerActionButton);
      expect(
        tester.widget<ComposerActionButton>(send).primary,
        ComposerAction.send,
      );
      expect(send.hitTestable(), findsOneWidget);
      await tester.tap(send);
      await until(
        tester,
        () => chat.composer.observation.queue.isNotEmpty,
        'Send stores the original draft while connection recovery is paused.',
      );
      expect(chat.composer.observation.text, isEmpty);
      expect(
        chat.composer.observation.queue.single.text,
        'My unsent follow-up',
      );
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);

      host.resumeError = null;
      final recovery = Completer<void>();
      host.resumeDelay = recovery;
      try {
        expect(retry.hitTestable(), findsOneWidget);
        await tester.tap(retry);
        await until(
          tester,
          () =>
              controller.connectionStatus.phase ==
                  ServerConnectionPhase.reconnecting &&
              find.byType(StudioLoading).evaluate().isNotEmpty,
          'Retry starts recovery and renders visible pending feedback.',
        );
        expect(chat.runtime.openingError, isNull);
        expect(find.byType(StudioLoading), findsOneWidget);
        await controller.updateDraft(chat, 'Edited while reconnecting');
        recovery.complete();
        await until(
          tester,
          () =>
              !chat.runtime.opening &&
              !chat.composer.observation.sending &&
              chat.composer.observation.queue.isEmpty,
          'Recovery submits the queued message and preserves the newer draft.',
        );
      } finally {
        if (!recovery.isCompleted) recovery.complete();
        await tester.pump();
      }
      expect(controller.notificationChat, isNull);
      expect(controller.current!.chat, same(chat));
      expect(chat.runtime.opening, isFalse);
      expect(chat.composer.observation.text, 'Edited while reconnecting');
      expect(
        controller.connectionStatus.phase,
        ServerConnectionPhase.connected,
      );
      expect(
        tester
            .widget<ComposerActionButton>(find.byType(ComposerActionButton))
            .unavailable[ComposerAction.send],
        isNull,
      );
      final submitted = host.calls
          .where((call) => call.$2 == 'prompt.submit')
          .single;
      expect(submitted.$3['text'], 'My unsent follow-up');
      final inputId = submitted.$3['submission_id'];
      expect(inputId, isA<String>());
      expect(inputId, isNotEmpty);
      expect(host.canonicalAdmissions, hasLength(1));
      final receipt = host.canonicalAdmissions.values.single;
      expect(receipt['input_id'], inputId);
      expect((receipt['ref'] as Map)['session_id'], chat.runtime.runtimeId);
      expect(chat.composer.observation.queue, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final failure in [
    JsonRpcError(
      'session.resume',
      'session disconnect interrupt settling',
      code: 4009,
    ),
    JsonRpcError(
      'session.resume',
      'session no longer live; retry resume',
      code: 4007,
    ),
    JsonRpcError('session.resume', 'Failed to resume session', code: 5000),
    JsonRpcError('session.resume', 'internal error', code: -32603),
  ]) {
    testWidgets(
      'resume ${failure.code} recovers automatically without resending',
      (tester) async {
        host.resumeError = failure;
        await controller.openNotification(chat.key);
        expect(chat.runtime.openingError, isNull);
        expect(
          controller.connectionStatus.phase,
          ServerConnectionPhase.reconnecting,
        );
        host.resumeError = null;
        await tester.pump(const Duration(seconds: 1));
        expect(host.resumeCalls, 2);
        expect(controller.notificationChat, isNull);
        expect(chat.runtime.opening, isFalse);
        expect(chat.composer.observation.text, 'My unsent follow-up');
        expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
      },
    );
  }

  testWidgets(
    'foreground resume retries a gateway internal error without user action',
    (tester) async {
      host.resumeError = JsonRpcError(
        'session.resume',
        'internal error',
        code: -32603,
      );
      await controller.resumeConnection();
      expect(controller.current!.reconnectError, isNull);
      expect(controller.recovering, isTrue);
      expect(host.resumeCalls, 1);

      host.resumeError = null;
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(host.resumeCalls, 2);
      expect(controller.recovering, isFalse);
      expect(controller.current!.chat, same(chat));
      expect(chat.composer.observation.text, 'My unsent follow-up');
      expect(chat.reading.messages.single['content'], 'a completed');
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
    },
  );

  testWidgets('notification retries automatically after a prolonged outage', (
    tester,
  ) async {
    host.resumeError = TimeoutException('Synthetic resume timeout');
    await controller.openNotification(chat.key);
    for (final seconds in [1, 2, 4, 8, 16]) {
      await tester.pump(Duration(seconds: seconds));
    }
    expect(host.resumeCalls, 6);
    expect(chat.runtime.openingError, isNull);
    expect(
      controller.connectionStatus.phase,
      ServerConnectionPhase.reconnecting,
    );
    expect(chat.composer.observation.text, 'My unsent follow-up');
    host.resumeError = null;
    await tester.pump(const Duration(seconds: 29));
    expect(host.resumeCalls, 6);
    await tester.pump(const Duration(seconds: 1));
    expect(host.resumeCalls, 7);
    expect(controller.notificationChat, isNull);
    expect(chat.runtime.opening, isFalse);
    expect(controller.connectionStatus.phase, ServerConnectionPhase.connected);
    expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
  });

  testWidgets('reopening a cached chat bypasses its pending recovery delay', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          createBotsSession: () => BotsSession((_) async => const []),
          controller: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    host.resumeError = TimeoutException('Network asleep');
    await controller.openNotification(chat.key);
    for (final seconds in [1, 2, 4, 8, 16]) {
      await tester.pump(Duration(seconds: seconds));
    }
    expect(chat.runtime.openingError, isNull);
    final calls = host.resumeCalls;
    host.resumeError = null;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(host.resumeCalls, calls + 1);
    expect(chat.runtime.openingError, isNull);
    expect(chat.runtime.opening, isFalse);
    expect(controller.notificationChat, isNull);
    expect(chat.composer.observation.text, 'My unsent follow-up');
    expect(retry, findsNothing);
    expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'visible notification retries a failed opening already in flight',
    (tester) async {
      host.resumeError = JsonRpcError('session.resume', 'Session unavailable');
      host.failResumeOnce = true;
      host.resumeDelay = Completer<void>();
      final opening = controller.openNotification(chat.key);
      await tester.pump();
      expect(host.resumeCalls, 1);

      await tester.pumpWidget(
        MaterialApp(
          home: ProfileWorkspaceScreen(
            createBotsSession: () => BotsSession((_) async => const []),
            controller: controller,
          ),
        ),
      );
      await tester.pump();
      host.resumeDelay!.complete();
      await opening;
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();

      expect(host.resumeCalls, 2);
      expect(chat.runtime.openingError, isNull);
      expect(chat.runtime.opening, isFalse);
      expect(controller.notificationChat, isNull);
      expect(chat.composer.observation.text, 'My unsent follow-up');
      expect(retry, findsNothing);
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
