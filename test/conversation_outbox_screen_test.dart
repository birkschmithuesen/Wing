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
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/composer_draft_store.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/composer_action_button.dart';
import 'package:wing/core/widgets/profile_queued_messages.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'profile_workspace_controller_test.dart' show Host;

void main() {
  const capture = bool.fromEnvironment('CAPTURE_OUTBOX');
  final disposed = <ProfileWorkspaceController>{};
  void dispose(ProfileWorkspaceController controller) {
    if (disposed.add(controller)) controller.dispose();
  }

  setUpAll(() async {
    if (!capture) return;
    const fonts = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(
              '$fonts/${entry.value}',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });

  Future<void> snapshot(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('outbox-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/outbox-review/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<ProfileWorkspaceController> initialize(Host host) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final appPreferences = AppPreferences(preferences);
    addTearDown(appPreferences.dispose);
    final controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'outbox-screen',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    addTearDown(() => dispose(controller));
    await controller.initialize();
    await controller.createChat(canDispatch: () => true);
    return controller;
  }

  Future<void> render(
    WidgetTester tester,
    ProfileWorkspaceController controller, {
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: wingTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            viewInsets: const EdgeInsets.only(bottom: 280),
          ),
          child: child!,
        ),
        home: RepaintBoundary(
          key: const ValueKey('outbox-capture'),
          child: ProfileWorkspaceScreen(
            createBotsSession: () => BotsSession((_) async => const []),
            controller: controller,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  final editor = find.byKey(const Key('profile-message-composer'));
  final send = find.byType(ComposerActionButton);
  Finder queuedText(String text) => find.descendant(
    of: find.byType(ProfileQueuedMessages),
    matching: find.text(text),
  );

  testWidgets('Send waits for the requested attachment to finish preparing', (
    tester,
  ) async {
    final host = Host()..running = false;
    final controller = await initialize(host);
    final chat = controller.current!.chat!;
    await render(tester, controller);
    await tester.enterText(editor, 'Include the image I am pasting');
    final clipboard = Completer<Uint8List>();
    final preparing = controller.addPastedImage(chat, () => clipboard.future);
    final cancelled = expectLater(preparing, throwsStateError);
    try {
      await tester.pump();
      expect(chat.composer.observation.preparing, isTrue);
      final button = tester.widget<ComposerActionButton>(send);
      expect(button.unavailable[ComposerAction.send], contains('attachment'));
      expect(button.unavailable[ComposerAction.queue], contains('attachment'));
      await tester.tap(send);
      await tester.pump();
      expect(chat.composer.observation.text, 'Include the image I am pasting');
      expect(chat.composer.observation.queue, isEmpty);
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
    } finally {
      clipboard.completeError(StateError('Paste cancelled'));
      await cancelled;
      await tester.pump();
    }
    expect(chat.composer.observation.preparing, isFalse);
    expect(
      tester
          .widget<ComposerActionButton>(send)
          .unavailable[ComposerAction.send],
      isNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    dispose(controller);
    await tester.pump();
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('offline Send saves FIFO ${brightness.name} at $scale', (
        tester,
      ) async {
        final host = Host()..running = false;
        final controller = await initialize(host);
        final chat = controller.current!.chat!;
        host.discoveryFailure = const SocketException('Offline');
        controller.networkUnavailable();
        await render(tester, controller, brightness: brightness, scale: scale);
        controller.connectionStatus.liveChanged(
          chat.key.workspace.profileName,
          false,
        );
        for (final message in [
          'First offline message',
          'Second offline message',
        ]) {
          await tester.enterText(editor, message);
          await tester.pump();
          final button = tester.widget<ComposerActionButton>(send);
          expect(button.primary, ComposerAction.send);
          expect(button.unavailable[ComposerAction.send], isNull);
          expect(button.unavailable[ComposerAction.steer], isNotNull);
          await tester.tap(send);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(chat.composer.observation.text, isEmpty);
        expect(tester.widget<TextField>(editor).controller!.text, isEmpty);
        expect(chat.composer.observation.queue.map((message) => message.text), [
          'First offline message',
          'Second offline message',
        ]);
        expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
        final stored = await ComposerDraftStore(
          controller.preferences,
          connectionIdentity: 'outbox-screen',
        ).read(profileName: 'a', sessionId: chat.key.sessionId);
        expect(stored!.text, isEmpty);
        expect(stored.queuedPrompts.map((message) => message.text), [
          'First offline message',
          'Second offline message',
        ]);
        await tester.tap(find.text('2 queued'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('First offline message'), findsOneWidget);
        expect(find.text('Second offline message'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await snapshot(tester, 'offline-${brightness.name}-$scale');
        await tester.pumpWidget(const SizedBox.shrink());
        dispose(controller);
        await tester.pump();
      });
    }
  }

  testWidgets('Send stays usable while the earlier message awaits ACK', (
    tester,
  ) async {
    final host = Host()..running = false;
    final controller = await initialize(host);
    final chat = controller.current!.chat!;
    host.promptSubmitStarted = Completer<void>();
    host.promptSubmitDelay = Completer<void>();
    await render(tester, controller);
    await tester.enterText(editor, 'First message');
    await tester.pump();
    await tester.tap(send);
    for (var i = 0; i < 30 && !host.promptSubmitStarted!.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(host.promptSubmitStarted!.isCompleted, isTrue);
    await tester.tap(find.text('1 queued'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      queuedText('Delivery unconfirmed · First message').hitTestable(),
      findsOneWidget,
    );
    try {
      await tester.enterText(editor, 'Second message');
      await tester.pump();
      final button = tester.widget<ComposerActionButton>(send);
      expect(button.primary, ComposerAction.send);
      expect(button.unavailable[ComposerAction.send], isNull);
      await tester.tap(send);
      await tester.pump();
      await tester.enterText(editor, 'Fresh editable draft');
      await tester.pump();
      expect(chat.composer.observation.queue.map((message) => message.text), [
        'First message',
        'Second message',
      ]);
      expect(
        queuedText('Delivery unconfirmed · First message'),
        findsOneWidget,
      );
      expect(queuedText('Second message'), findsOneWidget);
      expect(
        host.calls.where((call) => call.$2 == 'prompt.submit'),
        hasLength(1),
      );
      await snapshot(tester, 'awaiting-ack');
    } finally {
      host.promptSubmitDelay!.complete();
      for (var i = 0; i < 30 && chat.composer.observation.sending; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
    }
    expect(chat.composer.observation.sending, isFalse);
    expect(chat.composer.observation.text, 'Fresh editable draft');
    expect(chat.composer.observation.queue.single.text, 'Second message');
    expect(chat.composer.observation.queue.single.serverOwned, isTrue);
    expect(queuedText('Delivery unconfirmed · First message'), findsNothing);
    expect(queuedText('Second message').hitTestable(), findsOneWidget);
    expect(
      tester.widget<ComposerActionButton>(send).primary,
      ComposerAction.steer,
    );
    host.promptSubmitStarted = null;
    host.promptSubmitDelay = null;
    host.event(chat.key.workspace.profileName, 'turn.end', {
      'status': 'completed',
    });
    for (var i = 0; i < 30 && chat.composer.observation.queue.isNotEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(chat.composer.observation.queue, isEmpty);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(queuedText('Second message'), findsNothing);
    expect(tester.getSize(find.byType(ProfileQueuedMessages)).height, 0);
    expect(chat.composer.observation.text, 'Fresh editable draft');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    dispose(controller);
    await tester.pump();
  });
}
