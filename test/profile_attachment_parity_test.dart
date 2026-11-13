import 'support/composer_fixture.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/attachment_draft.dart';
import 'package:wing/core/models/user_message_content.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'profile_workspace_controller_test.dart' show Host;

void main() {
  late Host host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ProfileChat chat;
  late Directory cache;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    cache = await Directory.systemTemp.createTemp('hermes-attachment-parity-');
    host = Host();
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
      connectionIdentity: 'attachment-parity',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
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
    controller.dispose();
    appPreferences.dispose();
    await cache.delete(recursive: true);
  });

  Future<AttachmentDraft> attach(String name, {bool image = false}) async {
    final file = File('${cache.path}/$name');
    await file.writeAsBytes([1, 2, 3, 4]);
    final draft = AttachmentDraft(
      id: name,
      cachedPath: file.path,
      name: name,
      byteLength: 4,
      mediaType: image ? 'image/png' : 'text/plain',
      kind: image ? AttachmentDraftKind.image : AttachmentDraftKind.genericFile,
      sanitized: image,
    );
    await restoreComposerFixture(
      chat: chat,
      preferences: controller.preferences,
      appendAttachments: [draft],
    );
    return draft;
  }

  test('images use Desktop image bytes and an image-only prompt', () async {
    await attach('picture.png', image: true);
    await controller.send(chat);
    final upload = host.calls.singleWhere(
      (call) => call.$2 == 'image.attach_bytes',
    );
    expect(upload.$3, {
      'profile': 'a',
      'session_id': chat.runtime.runtimeId,
      'filename': 'picture.png',
      'content_base64': base64Encode([1, 2, 3, 4]),
    });
    expect(host.calls.where((call) => call.$2 == 'file.attach'), isEmpty);
    expect(
      host.calls.singleWhere((call) => call.$2 == 'prompt.submit').$3['text'],
      'What do you see in this image?',
    );
    expect(chat.composer.observation.attachments, isEmpty);
    final sent = UserMessageContent.fromMessage(chat.reading.messages.last);
    expect(sent.text, isEmpty);
    expect(sent.attachments.single.name, 'picture.png');
    expect(sent.attachments.single.target, '/profile/images/upload.png');
    expect(sent.attachments.single.isImage, isTrue);
  });

  test(
    'mixed attachments put file references before the user prompt',
    () async {
      await attach('picture.png', image: true);
      await attach('notes.txt');
      await controller.updateDraft(chat, 'Read these.');
      await controller.send(chat);
      expect(
        host.calls.where((call) => call.$2 == 'image.attach_bytes').length,
        1,
      );
      expect(
        host.calls.singleWhere((call) => call.$2 == 'prompt.submit').$3['text'],
        'attached:notes.txt\n\nRead these.',
      );
      final sent = UserMessageContent.fromMessage(chat.reading.messages.last);
      expect(sent.text, 'Read these.');
      expect(sent.attachments.map((file) => file.name), [
        'picture.png',
        'notes.txt',
      ]);
      expect(sent.attachments.last.extension, 'TXT');
    },
  );

  test('rejected image stays unsent and retains its cache', () async {
    final draft = await attach('picture.png', image: true);
    host.imageAttachResult = {'attached': false, 'message': 'Image rejected'};
    await controller.send(chat);
    expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
    expect(
      chat.composer.observation.queue.single.attachments.single.status,
      AttachmentDraftStatus.failed,
    );
    expect(await File(draft.cachedPath).exists(), isTrue);
    expect(chat.runtime.error, contains('Image rejected'));
  });

  test(
    'retry after a later file fails does not attach the image twice',
    () async {
      await attach('picture.png', image: true);
      await attach('notes.txt');
      host.fileAttachFails = true;
      await controller.send(chat);
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
      expect(chat.composer.observation.attachments, isEmpty);
      expect(chat.composer.observation.queue, hasLength(1));
      expect(chat.composer.observation.paused, isTrue);
      host
        ..fileAttachFails = false
        ..running = false;
      await controller.resumeQueue(chat);
      expect(
        host.calls.where((call) => call.$2 == 'image.attach_bytes').length,
        1,
      );
      expect(host.calls.where((call) => call.$2 == 'prompt.submit').length, 1);
      expect(host.calls.where((call) => call.$2 == 'file.attach').length, 2);
      expect(chat.composer.observation.queue, isEmpty);
      expect(await File('${cache.path}/picture.png').exists(), isFalse);
      expect(await File('${cache.path}/notes.txt').exists(), isFalse);
    },
  );

  test(
    'discarding a failed outbox message drops its uploaded image reference',
    () async {
      final image = await attach('picture.png', image: true);
      final notes = await attach('notes.txt');
      host.fileAttachFails = true;
      await controller.send(chat);
      expect(chat.composer.observation.attachments, isEmpty);
      final outgoing = chat.composer.observation.queue.single;
      expect(outgoing.attachments.map((file) => file.id), [image.id, notes.id]);
      expect(outgoing.submissionUncertain, isFalse);
      await controller.updateDraft(chat, 'Fresh composer');
      await controller.removeQueuedPrompt(chat, outgoing.id);
      // Canonical image uploads are references owned by the submission.
      // Removing unsent work drops its reference without mutating another turn.
      expect(host.calls.where((call) => call.$2 == 'image.detach'), isEmpty);
      expect(chat.composer.observation.attachments, isEmpty);
      expect(chat.composer.observation.queue, isEmpty);
      expect(chat.composer.observation.text, 'Fresh composer');
      expect(await File(image.cachedPath).exists(), isFalse);
      expect(await File(notes.cachedPath).exists(), isFalse);
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
      host
        ..fileAttachFails = false
        ..running = false;
      await controller.resumeQueue(chat);
      await controller.send(chat);
      expect(
        host.calls.where((call) => call.$2 == 'prompt.submit'),
        hasLength(1),
      );
      expect(
        host.calls.where((call) => call.$2 == 'image.attach_bytes'),
        hasLength(1),
      );
      final fresh = host.calls
          .singleWhere((call) => call.$2 == 'prompt.submit')
          .$3;
      expect(fresh['text'], 'Fresh composer');
      expect(fresh.containsKey('attachments'), isFalse);
    },
  );

  test('replacement runtime reuploads the retained image bytes', () async {
    final image = await attach('picture.png', image: true);
    await attach('notes.txt');
    host.fileAttachFails = true;
    await controller.send(chat);
    expect(await File(image.cachedPath).exists(), isTrue);
    expect(chat.composer.observation.attachments, isEmpty);
    expect(
      chat.composer.observation.queue.single.attachments.first.id,
      image.id,
    );
    expect(chat.composer.observation.queue.single.submissionUncertain, isFalse);
    host
      ..sessionCreates = 2
      ..fileAttachFails = false
      ..running = false;
    await controller.resumeQueue(chat);
    final uploads = host.calls.where((call) => call.$2 == 'image.attach_bytes');
    expect(uploads.length, 2);
    expect(chat.runtime.runtimeId, 'a-replacement-runtime');
    expect(uploads.last.$3['session_id'], chat.runtime.runtimeId);
    expect(uploads.last.$3['content_base64'], base64Encode([1, 2, 3, 4]));
    expect(host.calls.where((call) => call.$2 == 'prompt.submit').length, 1);
    expect(chat.composer.observation.queue, isEmpty);
    expect(await File(image.cachedPath).exists(), isFalse);
  });
}
