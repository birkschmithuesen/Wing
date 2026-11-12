import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/image_clipboard.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';

import '../test/support/profile_actions_fixture.dart';
import '../test/support/composer_fixture.dart';

/// The nightly driver supplies the synthetic PNG from a separate Android UID.
/// This exercises real clipboard grants and Paste without contacting a gateway.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'synthetic image clip crosses Android clipboard with exact pixels',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: TextField(autofocus: true))),
      );
      await tester.pumpAndSettle();
      expect(
        await ImageClipboard.hasImage(),
        isTrue,
        reason: 'Run the owned clipboard fixture before this suite.',
      );
      final bytes = await ImageClipboard.readImage();
      expect(bytes, isNotEmpty);
      final codec = await ui.instantiateImageCodec(bytes);
      addTearDown(codec.dispose);
      final frame = await codec.getNextFrame();
      addTearDown(frame.image.dispose);
      expect((frame.image.width, frame.image.height), (32, 32));
      final pixels = (await frame.image.toByteData())!.buffer.asUint8List();
      expect(
        pixels,
        List.generate(
          32 * 32 * 4,
          (index) => [0x20, 0x90, 0xc0, 0xff][index % 4],
        ),
      );
    },
    skip: !const bool.fromEnvironment('HERMES_CLIPBOARD_DEVICE_TEST'),
  );

  testWidgets(
    'long-press Paste stages an image beside a picked-image thumbnail',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final fixture = ProfileActionsFixture();
      final fixturePreferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(fixturePreferences);
      addTearDown(appPreferences.dispose);
      final controller = ProfileWorkspaceController(
        appPreferences: appPreferences,
        access: ConnectionAccess(
          connection: SavedConnection(
            id: 'clipboard-device-qa',
            label: 'Clipboard device QA',
            host: 'unused',
            port: 1,
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'isolated-clipboard-device-qa',
        preferences: fixturePreferences,
        gatewayFactory: fixture.gateway,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final chat = await controller.createChat(canDispatch: () => true);
      emitChatEvent(controller, chat, 'session.title', {
        'session_id': chat.key.sessionId,
        'title': 'Image attachment check',
      });
      emitChatEvent(controller, chat, 'message.start');
      emitChatEvent(controller, chat, 'session.info', {
        'open_requests': [],
        'running': false,
      });
      addTearDown(() async {
        for (final file in chat.composer.observation.attachments.toList()) {
          await controller.removeAttachment(chat, file.id);
        }
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
      final composer = find.byKey(const Key('profile-message-composer'));
      await tester.longPress(composer);
      await tester.pumpAndSettle();
      expect(find.text('Paste'), findsOneWidget);
      await tester.tap(find.text('Paste'));
      for (
        var frame = 0;
        frame < 150 && chat.composer.observation.attachments.isEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(chat.composer.observation.attachments, hasLength(1));
      final pasted = (await readComposerFixture(
        chat: chat,
        preferences: fixturePreferences,
      ))!.attachments.single;
      expect(pasted.sanitized, isTrue);
      await controller.addAttachments(chat, [
        (path: pasted.cachedPath, name: 'Selected photo.png'),
      ]);
      await tester.pumpAndSettle();
      final thumbnails = find.byKey(const ValueKey('composer-image-thumbnail'));
      expect(thumbnails, findsNWidgets(2));
      final composerBox = tester.getRect(
        find.byKey(const ValueKey('conversation-composer')),
      );
      for (final thumbnail in [thumbnails.first, thumbnails.last]) {
        expect(thumbnail.hitTestable(), findsOneWidget);
        expect(composerBox.contains(tester.getRect(thumbnail).center), isTrue);
      }
      await binding.convertFlutterSurfaceToImage();
      await tester.pumpAndSettle();
      final screenshot = await binding.takeScreenshot('clipboard-thumbnails');
      final directory = await getExternalStorageDirectory();
      await File(
        '${directory!.path}/clipboard-thumbnails.png',
      ).writeAsBytes(screenshot);
      await tester.tap(find.byTooltip('Remove ${pasted.name}'));
      await tester.pumpAndSettle();
      expect(
        chat.composer.observation.attachments.single.name,
        'Selected photo.png',
      );
    },
    skip: !const bool.fromEnvironment('HERMES_CLIPBOARD_DEVICE_TEST'),
  );
}
