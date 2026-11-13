import 'support/composer_fixture.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image_lib;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/attachment_draft_service.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

import 'profile_workspace_controller_test.dart' show Host;

void main() {
  late Directory directory;
  late Directory cache;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ProfileChat chat;
  var disposed = false;
  Completer<void>? writeStarted;
  Completer<void>? releaseWrite;
  var writes = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('wing-image-authority-');
    cache = Directory('${directory.path}/cache');
    disposed = false;
    writes = 0;
    writeStarted = null;
    releaseWrite = null;
    final service = AttachmentDraftService(
      cacheDirectoryProvider: () async => cache,
      cacheFileWriter: (destination, bytes) async {
        writes++;
        await destination.writeAsBytes(bytes);
        if (writes == 1 && writeStarted != null) {
          writeStarted!.complete();
          await releaseWrite!.future;
        }
      },
    );
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'host',
          label: 'Host',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'image-authority',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: Host().gateway,
      attachmentService: service,
    );
    await controller.initialize();
    chat = await controller.createChat(canDispatch: () => true);
    emitChatEvent(controller, chat, 'message.start');
    emitChatEvent(controller, chat, 'session.info', {
      'open_requests': [],
      'running': false,
    });
  });
  tearDown(() async {
    if (!disposed) controller.dispose();
    appPreferences.dispose();
    if (releaseWrite != null && !releaseWrite!.isCompleted) {
      releaseWrite!.complete();
    }
    await directory.delete(recursive: true);
  });

  Uint8List image() =>
      image_lib.encodePng(image_lib.Image(width: 2, height: 2));

  test(
    'cancellation before clipboard completion cannot register new work',
    () async {
      final clipboard = Completer<Uint8List>();
      final preparation = controller.addPastedImage(
        chat,
        () => clipboard.future,
      );
      final failure = expectLater(preparation, throwsA(isA<StateError>()));
      chat.composer.cancelPreparation();
      try {
        await failure.timeout(const Duration(seconds: 2));
        expect(chat.composer.observation.preparing, isFalse);
        expect(controller.canAddAttachment(chat), isTrue);
      } finally {
        clipboard.complete(image());
      }
      await Future<void>.delayed(Duration.zero);
      expect(writes, 0);
      expect(chat.composer.observation.attachments, isEmpty);
      expect(chat.composer.observation.preparing, isFalse);
      expect(await cache.exists(), isFalse);
    },
  );

  test(
    'disposal before clipboard completion cannot publish or create cache files',
    () async {
      final clipboard = Completer<Uint8List>();
      final preparation = controller.addPastedImage(
        chat,
        () => clipboard.future,
      );
      final failure = expectLater(preparation, throwsA(isA<StateError>()));
      controller.dispose();
      disposed = true;
      try {
        await failure.timeout(const Duration(seconds: 2));
        expect(chat.composer.observation.preparing, isFalse);
      } finally {
        clipboard.complete(image());
      }
      await Future<void>.delayed(Duration.zero);
      expect(writes, 0);
      expect(chat.composer.observation.attachments, isEmpty);
    },
  );

  test(
    'cancelling one chat during cache commit preserves another chat preparation',
    () async {
      writeStarted = Completer<void>();
      releaseWrite = Completer<void>();
      final first = controller.addPastedImage(chat, () async => image());
      final failure = expectLater(
        first,
        throwsA(isA<AttachmentDraftException>()),
      );
      await writeStarted!.future;
      final other = await controller.createChat(canDispatch: () => true);
      emitChatEvent(controller, other, 'message.start');
      emitChatEvent(controller, other, 'session.info', {
        'open_requests': [],
        'running': false,
      });
      await controller.addPastedImage(other, () async => image());
      chat.composer.cancelPreparation();
      releaseWrite!.complete();
      await failure;
      expect(chat.composer.observation.attachments, isEmpty);
      expect(other.composer.observation.attachments, hasLength(1));
      expect(
        await File(
          (await readComposerFixture(
            chat: other,
            preferences: controller.preferences,
          ))!.attachments.single.cachedPath,
        ).exists(),
        isTrue,
      );
      expect(await cache.list().toList(), hasLength(1));
    },
  );

  test(
    'chat deletion while cache write is held removes only unpublished output',
    () async {
      writeStarted = Completer<void>();
      releaseWrite = Completer<void>();
      final preparation = controller.addPastedImage(chat, () async => image());
      final failure = expectLater(
        preparation,
        throwsA(isA<AttachmentDraftException>()),
      );
      await writeStarted!.future;
      await controller.mutateSession(
        chat.key,
        delete: true,
        canDispatch: () => true,
      );
      releaseWrite!.complete();
      await failure;
      expect(controller.current!.chats.containsValue(chat), isFalse);
      expect(await cache.list().toList(), isEmpty);
    },
  );
}
