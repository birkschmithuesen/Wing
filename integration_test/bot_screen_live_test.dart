import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/group_observations.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wing/core/screens/bots/bot_screen_view.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/bot_screen_session.dart';
import 'package:wing/core/widgets/bot_display_surface.dart';
import 'package:wing/core/services/bots_repository.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/theme/wing_theme.dart';

import '../test/support/existing_backend_login.dart';

/// Opt-in, mutating acceptance on an owned emulator and approved live bot.
/// The host driver supplies a harmless input window and verifies its events.
/// Never takes an existing human lease or submits a model prompt. Credentials
/// remain in a runtime private file. Finally releases only this viewer's lease.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized()
          .shouldPropagateDevicePointerEvents =
      true;
  const enabled = bool.fromEnvironment('BOT_SCREEN_LIVE');
  testWidgets(
    'live bot screen takeover with Android input',
    (tester) async {
      const url = String.fromEnvironment('WING_HERMES_URL');
      const login = String.fromEnvironment('WING_HERMES_LOGIN_FILE');
      const profile = String.fromEnvironment('BOT_SCREEN_PROFILE');
      expect(url.isNotEmpty && login.isNotEmpty && profile.isNotEmpty, isTrue);
      final connection = await readExistingBackendConnection(
        url: url,
        loginFile: login,
        id: 'bot-screen-live-qa',
      );
      final status = ServerConnectionStatus('Live screen QA');
      final server = AdministrationRepository.forConnection(
        ConnectionAccess(connection: connection, dashboardOAuth: null),
        connection.id,
        connectionStatus: status,
      );
      final repository = BotsRepository.forServer(
        server,
        groupObservations: GroupObservations(
          WorkspaceScope(
            connectionId: (server).connectionId,
            connectionIdentity: (server).connectionIdentity,
            profileName: 'default',
          ),
        ),
      );
      BotScreenSession? session;
      var started = false;

      Future<void> until(bool Function() condition, String reason) async {
        final end = DateTime.now().add(const Duration(seconds: 60));
        while (!condition() && DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(condition(), isTrue, reason: reason);
      }

      Future<void> native(
        String name, {
        String action = 'capture',
        Offset? point,
      }) async {
        final cache = Directory.systemTemp.path;
        final token = '$name-${DateTime.now().microsecondsSinceEpoch}';
        await File('$cache/wing-screen-stage.json').writeAsString(
          jsonEncode({
            'name': name,
            'action': action,
            'token': token,
            if (point != null) 'point': [point.dx.round(), point.dy.round()],
          }),
        );
        final ack = File('$cache/wing-screen-ack');
        final deadline = DateTime.now().add(const Duration(seconds: 60));
        // A hidden Android activity produces no Flutter frames. Keep the native
        // bridge moving on real timers, so the host can later resume the app.
        while (DateTime.now().isBefore(deadline) &&
            !(ack.existsSync() && ack.readAsStringSync() == token)) {
          if (action == 'background' || action == 'resume') {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          } else {
            await tester.pump(const Duration(milliseconds: 100));
          }
        }
        expect(
          ack.existsSync() && ack.readAsStringSync() == token,
          isTrue,
          reason: 'Host driver must verify $name before acknowledging it',
        );
        if (action != 'background') {
          await tester.pump(const Duration(milliseconds: 300));
        }
      }

      Future<void> command(String label) async {
        if (find.byTooltip(label).evaluate().isEmpty) {
          await tester.tap(find.byTooltip('More screen controls'));
          await tester.pump();
        }
        await tester.ensureVisible(find.byTooltip(label));
        await tester.tap(find.byTooltip(label));
        await tester.pump();
      }

      BotDisplaySurface surface() =>
          tester.widget<BotDisplaySurface>(find.byType(BotDisplaySurface));
      Offset phonePoint(Offset local) =>
          tester
              .renderObject<RenderBox>(find.byType(BotDisplaySurface))
              .localToGlobal(local) *
          tester.view.devicePixelRatio;
      try {
        final bots = await repository.bots();
        final bot = bots.singleWhere((bot) => bot.profile.name == profile);
        final initial = await repository.displayStatus(bot);
        expect(initial.lease.holder, 'agent', reason: 'Never evict a human');
        expect(initial.supported && initial.installed, isTrue);
        session = BotScreenSession(repository, bot);
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: wingTheme(Brightness.dark),
            home: Builder(
              builder: (context) => Scaffold(
                body: IconButton(
                  tooltip: 'Open QA screen',
                  icon: const Icon(Icons.desktop_windows),
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => BotScreenView(
                        createSession: () => session!,
                        conversation: session!,
                        readConversation: () => [],
                        readRequest: () => null,
                        sendMessage: null,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byTooltip('Open QA screen'));
        await until(() => session!.status != null, 'Screen status arrives');
        if (!initial.running) {
          started = true;
          await until(() => session!.canStart, 'Start becomes available');
          await command('Start screen');
          await tester.tap(find.byTooltip('More screen controls'));
          await tester.pump();
        }
        await until(() => session!.connected, 'Real RFB frame arrives');
        await until(
          () => tester
              .widgetList<RawImage>(find.byType(RawImage))
              .any((image) => image.image != null),
          'Native pixel image decodes',
        );
        expect(session.controlling, isFalse);
        await native('watch');
        await until(() => session!.canTakeOver, 'Takeover admission available');
        await tester.tap(find.byTooltip('Take control'));
        await until(
          () => session!.canInput,
          'Own lease confirms input authority',
        );
        expect(find.byTooltip('You have control'), findsOneWidget);
        final owned = (await repository.displayStatus(bot)).lease;
        await native('landscape', action: 'landscape');
        await until(
          () =>
              tester.view.physicalSize.width > tester.view.physicalSize.height,
          'Native rotation',
        );
        await until(
          () => session!.canInput,
          'Rotation preserves our input authority',
        );
        expect(find.byType(AppBar), findsNothing);
        await until(
          () => tester.view.padding.top == 0 && tester.view.padding.bottom == 0,
          'Native immersive bars hidden',
        );
        await native('fullscreen-landscape');
        await native('portrait', action: 'portrait');
        await until(
          () =>
              tester.view.physicalSize.width < tester.view.physicalSize.height,
          'Portrait restored',
        );
        await until(
          () => session!.canInput,
          'Portrait preserves our input authority',
        );
        expect(find.byType(AppBar), findsOneWidget);
        expect((await repository.displayStatus(bot)).lease.epoch, owned.epoch);
        await command('Enter fullscreen');
        await tester.pump();
        await native('prepare-input-window', action: 'prepare');
        await native(
          'remote-click',
          action: 'tap-screen',
          point: phonePoint(surface().viewport.size.center(Offset.zero)),
        );
        await native(
          'pan-and-tap',
          action: 'move-click',
          point: phonePoint(surface().viewport.size.center(Offset.zero)),
        );
        await command('Zoom in');
        await command('Zoom in');
        await command('Zoom in');
        await tester.tap(find.byTooltip('More screen controls'));
        await tester.pump();
        final v = surface().viewport;
        v.pan(
          v.size.center(Offset.zero) -
              v.toLocal(Offset(v.desktop.width / 2, v.desktop.height * .94)),
        );
        await tester.pump();
        await native(
          'zoomed-target',
          action: 'tap-screen',
          point: phonePoint(
            v.toLocal(Offset(v.desktop.width / 2, v.desktop.height * .94)),
          ),
        );
        final typingScale = v.scale;
        await tester.tap(find.byTooltip('Show keyboard'));
        await native('android-typing', action: 'type');
        await until(
          () =>
              tester.view.viewInsets.bottom > 0 &&
              v.size.height < v.baseSize.height,
          'Native keyboard occlusion reaches the rendered viewport',
        );
        await native(
          'keyboard-target-click',
          action: 'tap-screen',
          point: phonePoint(v.toLocal(v.pointer)),
        );
        expect(
          v.scale,
          closeTo(typingScale, .0001),
          reason: 'Keyboard must not shrink desktop',
        );
        expect(v.toLocal(v.pointer).dy, lessThanOrEqualTo(v.size.height));
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '\u200b',
        );
        await session.refresh();
        await tester.pump();
        expect(find.byType(TextField), findsOneWidget);
        await command('Backspace');
        await command('Tab');
        await command('Enter');
        await command('Scroll down');
        await native('remote-input-confirmed', action: 'verify-input');
        await native('close-keyboard', action: 'back');
        await until(
          () => find.byType(TextField).evaluate().isEmpty,
          'Native Back hides keyboard',
        );
        expect(v.scale, closeTo(typingScale, .0001));
        await native('exit-fullscreen', action: 'back');
        await until(
          () => find.byType(AppBar).evaluate().isNotEmpty,
          'Second Back exits fullscreen',
        );
        expect(session.canInput, true);
        expect((await repository.displayStatus(bot)).lease.epoch, owned.epoch);
        await native('background', action: 'background');
        expect(session.connected, isFalse);
        expect(session.canInput, isFalse);
        expect(session.frame, isNull);
        expect((await repository.displayStatus(bot)).lease.holder, 'human');
        await native('resume', action: 'resume');
        await until(() => session!.canInput, 'Resume preserves our own lease');
        expect(find.byType(TextField), findsNothing);
        await native('resumed');
        await until(() => !session!.busy, 'Handback admission available');
        await tester.tap(find.byTooltip('Hand control back'));
        await until(
          () => !session!.humanHasControl,
          'Explicit handback confirmed',
        );
        expect((await repository.displayStatus(bot)).lease.holder, 'agent');
        expect(session.canInput, isFalse);
        await native('handed-back');
        await until(() => session!.canTakeOver, 'Reacquire for exit test');
        await tester.tap(find.byTooltip('Take control'));
        await until(() => session!.canInput, 'Own exit-test lease acquired');
        await command('Close screen');
        await until(
          () => find.byType(BotScreenView).evaluate().isEmpty,
          'Route exit awaits own handback',
        );
        expect((await repository.displayStatus(bot)).lease.holder, 'agent');
        expect(tester.takeException(), isNull);
        await native('complete', action: 'cleanup');
      } finally {
        try {
          if (session != null) {
            final closed = await session.close();
            expect(closed, isTrue, reason: 'Own test lease must be released');
            if (started && closed) {
              final latest = await repository.displayStatus(session.bot);
              if (latest.lease.holder == 'agent') {
                await repository.screenPower(
                  session.bot,
                  false,
                  () => true,
                  () {},
                );
              }
            }
          }
        } finally {
          await tester.pumpWidget(const SizedBox());
          server.close();
          status.dispose();
        }
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
