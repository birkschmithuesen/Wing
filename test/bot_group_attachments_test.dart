import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/bots.dart';
import 'package:wing/core/models/composer_reference.dart';
import 'package:wing/core/models/transcript_message.dart';
import 'package:wing/core/models/user_message_content.dart';
import 'package:wing/core/services/android_share_intent_service.dart';
import 'package:wing/core/services/attachment_draft_service.dart';
import 'package:wing/core/services/bot_group_read_state.dart';
import 'package:wing/core/services/bot_group_session.dart';
import 'package:wing/core/services/bots_preferences.dart';
import 'package:wing/core/services/bots_repository.dart';
import 'package:wing/core/widgets/user_message_attachment.dart';

import 'support/bots_fixture.dart';

const manifest = {
  'attachment_id': 'att_00000000000000000000000000000001',
  'kind': 'file',
  'name': 'notes.txt',
  'mime': 'text/plain',
  'size': 5,
};

class _FailingDraftPreferences extends BotsPreferences {
  _FailingDraftPreferences(super.preferences);
  bool failWrite = false;
  bool failAcknowledge = false;

  @override
  Future<void> writeMessageDraft(
    String identity,
    String roomId,
    String text,
    List<ComposerReference> references, {
    List<BotGroupAttachment> attachments = const [],
    String? pendingEventId,
    String? pendingWireText,
    String? pendingText,
  }) {
    if (failWrite) throw StateError('Device unavailable');
    return super.writeMessageDraft(
      identity,
      roomId,
      text,
      references,
      attachments: attachments,
      pendingEventId: pendingEventId,
      pendingWireText: pendingWireText,
      pendingText: pendingText,
    );
  }

  @override
  Future<void> acknowledgeMessageDraft(
    String identity,
    String roomId,
    String eventId,
    String text,
    Iterable<String> attachmentIds,
  ) async {
    if (failAcknowledge) throw StateError('Device unavailable');
    await super.acknowledgeMessageDraft(
      identity,
      roomId,
      eventId,
      text,
      attachmentIds,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late BotsFixture fixture;
  late BotsPreferences preferences;
  late BotGroup group;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await BotsPreferences.load();
    directory = await Directory.systemTemp.createTemp(
      'wing-group-attachments-',
    );
    fixture = BotsFixture();
    group = (await fixture.repository.groupCatalog()).single;
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  BotGroupSession session() => BotGroupSession(
    fixture.repository,
    group,
    reads: BotGroupReadState(),
    preferences: preferences,
    groupMessages: null,
    appearances: FixedGroupAppearances(const []),
    attachmentService: AttachmentDraftService(
      cacheDirectoryProvider: () async => Directory('${directory.path}/cache'),
    ),
  );

  Future<AndroidSharedFile> file() async {
    final source = await File(
      '${directory.path}/notes.txt',
    ).writeAsString('hello');
    return AndroidSharedFile(
      path: source.path,
      name: 'notes.txt',
      mediaType: 'text/plain',
      byteLength: 5,
    );
  }

  test(
    'shared intake retry saves the same staged text and files once',
    () async {
      final storage = _FailingDraftPreferences(
        await SharedPreferences.getInstance(),
      );
      preferences = storage;
      final owner = session();
      addTearDown(owner.dispose);
      fixture.commandHook = (_, method, _) async =>
          method == 'groups.attachment.upload' ? manifest : null;
      storage.failWrite = true;
      final payload = AndroidSharePayload(
        id: 'share-1',
        text: 'Review',
        files: [await file()],
      );
      expect(await owner.stageSharedContent(payload), false);
      expect(owner.draftText, 'Review');
      expect(owner.attachments, hasLength(1));
      storage.failWrite = false;
      expect(await owner.stageSharedContent(payload), true);
      expect(owner.draftText, 'Review');
      expect(owner.attachments, hasLength(1));
      expect(
        fixture.commands.where((call) => call.$2 == 'groups.attachment.upload'),
        hasLength(1),
      );
    },
  );

  test(
    'accepted send stays accepted when local acknowledgement fails',
    () async {
      final storage = _FailingDraftPreferences(
        await SharedPreferences.getInstance(),
      );
      preferences = storage;
      final owner = session();
      addTearDown(owner.dispose);
      await owner.editMentions('Review');
      storage.failAcknowledge = true;
      expect(await owner.send('Review'), true);
      expect(owner.pendingText, isNull);
      expect(owner.draftText, isEmpty);
      expect(owner.error, contains('Message sent'));
      expect(fixture.events, hasLength(1));
    },
  );

  test(
    'upload is visible, fences Send, persists manifest and omits storage metadata',
    () async {
      final owner = session();
      addTearDown(owner.dispose);
      final held = Completer<void>();
      fixture.commandHook = (_, method, params) async {
        if (method != 'groups.attachment.upload') return null;
        expect(params['data_base64'], base64Encode(utf8.encode('hello')));
        expect(params['room_id'], group.id);
        expect(params['upload_id'], isNotEmpty);
        await held.future;
        return {...manifest, 'sha256': 'storage-only', 'state': 'uncommitted'};
      };
      final uploading = owner.addAttachments([await file()]);
      expect(owner.attachmentPreparation!.count, 1);
      expect(owner.canAddAttachments, false);
      expect(await owner.send('Too early'), false);
      held.complete();
      await uploading;
      expect(owner.attachmentPreparation, isNull);
      expect(owner.attachments.single.name, 'notes.txt');
      expect(
        preferences
            .messageDraft(group.scope.connectionIdentity, group.id)!
            .attachments
            .single
            .id,
        manifest['attachment_id'],
      );
      expect(await owner.send(''), true);
      final sent = fixture.commands.singleWhere(
        (call) => call.$2 == 'groups.send',
      );
      expect(sent.$3['payload'], {
        'text': '',
        'thread_id': sent.$3['event_id'],
        'attachments': [manifest],
      });
      expect(owner.attachments, isEmpty);
      await owner.refresh();
      final message = TranscriptMessage.discussion(
        group: group,
        event: owner.events.single,
      );
      expect(message.attachments.single.name, 'notes.txt');
    },
  );

  test(
    'unconfirmed attachment Send restores exact event and payload on reopening',
    () async {
      final owner = session();
      fixture.commandHook = (_, method, _) async =>
          method == 'groups.attachment.upload' ? manifest : null;
      await owner.addAttachments([await file()]);
      await owner.editMentions('Review');
      fixture.sendLost = true;
      expect(await owner.send('Review'), false);
      final first = fixture.commands.last.$3;
      owner.dispose();
      final reopened = session();
      addTearDown(reopened.dispose);
      expect(reopened.pendingText, 'Review');
      expect(reopened.canAddAttachments, false);
      expect(await reopened.send('Review'), true);
      expect(fixture.commands.last.$3, first);
      expect(fixture.events, hasLength(1));
      expect(reopened.attachments, isEmpty);
    },
  );

  test(
    'download is bound to committed event and rejects crossed identity',
    () async {
      final attachment = BotGroupAttachment.fromJson(manifest);
      fixture.readHook = (_, method, params) async {
        if (method != 'groups.attachment.download') return null;
        expect(params, {
          'room_id': group.id,
          'event_id': 'event-1',
          'attachment_id': attachment.id,
        });
        return {
          ...manifest,
          'event_id': 'other-event',
          'data_base64': 'aGVsbG8=',
        };
      };
      await expectLater(
        fixture.repository.downloadGroupAttachment(
          group,
          'event-1',
          attachment,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'member activity admits exact members and does not mark every room participant active',
    () {
      final decoded = BotsRepository.decodeGroupState(
        group.scope,
        group.instance,
        group.id,
        {
          'room': fixture.room,
          'driver_status': {
            'working': true,
            'blocked': false,
            'pending_actions': [],
            'member_activity': [
              {'member_id': 'atlas', 'status': 'running'},
            ],
          },
        },
      );
      final state = BotGroupState(
        room: decoded.room!,
        roomAvailable: true,
        runtimeAvailable: true,
        working: true,
        memberActivity: decoded.runtime!.memberActivity,
      );
      expect(state.activeMemberProfiles, {'atlas'});
      final observed = state.applyTo(group).withCatalogObservation(group);
      expect(observed.activeMemberProfiles, {'atlas'});
    },
  );

  testWidgets(
    'attachment download immediately shows progress, retains failure and retires late result',
    (tester) async {
      final gate = Completer<bool>();
      const attachment = UserMessageAttachment(
        name: 'notes.txt',
        target: '/group-attachments/e/a/notes.txt',
        isImage: false,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UserMessageAttachmentTile(
              attachment: attachment,
              onDownload: (_) => gate.future,
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Download notes.txt'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      gate.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(
        find.text('File could not be saved. Try downloading again.'),
        findsOneWidget,
      );
      final second = Completer<bool>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UserMessageAttachmentTile(
              attachment: attachment,
              onDownload: (_) => second.future,
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Download notes.txt'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      second.complete(true);
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
