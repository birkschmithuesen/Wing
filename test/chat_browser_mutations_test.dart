import 'package:wing/core/models/composer_reference.dart';
import 'package:wing/core/models/chat_browser_preferences.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/models/chat_list_view.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/models/attachment_draft.dart';
import 'package:wing/core/models/deleted_draft_cleanup.dart';
import 'package:wing/core/models/queued_prompt_draft.dart';
import 'package:wing/core/services/chat_browser_data.dart';
import 'package:wing/core/services/attachment_draft_service.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/composer_draft_store.dart';
import 'package:wing/core/services/deleted_draft_cleanup_store.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/workspace_snapshot_store.dart';
import 'package:wing/core/services/ws_client.dart';

import 'support/browser_mutations_fixture.dart';

void main() {
  late BrowserMutationsFixture host;
  late ProfileWorkspaceController controller;
  late ChatBrowserData data;
  late _FailingDraftStore drafts;
  late _FailingAttachmentService attachments;
  late SharedPreferences preferences;
  late AppPreferences appPreferences;
  late Directory managedCache;
  late _CleanupPreferences platform;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    platform = _CleanupPreferences();
    SharedPreferencesStorePlatform.instance = platform;
    host = BrowserMutationsFixture()..extraRows = 110;
    preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    drafts = _FailingDraftStore(preferences);
    managedCache = await Directory.systemTemp.createTemp(
      'wing-managed-drafts-',
    );
    attachments = _FailingAttachmentService(managedCache);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'host',
          label: 'Test',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'mutations',
      preferences: preferences,
      appPreferences: appPreferences,
      draftStore: drafts,
      attachmentService: attachments,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
    data = ChatBrowserData(controller);
    await data.refresh(archivedOnly: false);
  });
  tearDown(() async {
    data.dispose();
    controller.dispose();
    appPreferences.dispose();
    if (await managedCache.exists()) await managedCache.delete(recursive: true);
  });

  ProfileSessionKey key(String id) =>
      ProfileSessionKey(controller.current!.scope, id);
  ChatListEntry row(String id) =>
      data.entries.firstWhere((e) => e.sessionKey == key(id));

  DeletedDraftCleanupStore journal() => DeletedDraftCleanupStore(
    preferences,
    connectionId: 'host',
    connectionIdentity: 'mutations',
  );

  Future<void> settleCatalog() async {
    // Let the signal's scheduled read start, then await its observable finish.
    for (var n = 0; n < 100; n++) {
      await Future<void>.delayed(Duration.zero);
      if (!data.state.loading) return;
    }
    fail('The automatic catalog read did not settle');
  }

  void catalogChanged() => controller.current!.gateway.onEvent!(
    StreamEvent(type: 'sessions.changed', sessionId: '', data: const {}),
  );

  test('saved chat signal replaces untitled and unassigned metadata', () async {
    host.changes['personal'] = {
      'newest': {'title': null},
    };
    await controller.switchProfile('personal');
    await data.refresh(archivedOnly: false);
    expect(row('newest').title, isEmpty);
    expect(row('newest').project, isNull);

    host.changes['personal']!['newest'] = {
      'title': 'Plan Cairns flights',
      'cwd': '/Mobile app',
    };
    catalogChanged();
    await settleCatalog();
    expect(row('newest').title, 'Plan Cairns flights');
    expect(row('newest').project?.id, 'p2');
    expect(controller.current!.chat, isNull, reason: 'No reopen is required');

    host.resumeOverrides = {
      'info': {'profile_name': 'personal', 'title': 'Plan Cairns flights'},
    };
    final chat = await controller.openSession(key('newest'));
    await settleCatalog();
    expect(chat!.title, row('newest').title);
    expect(chat.projectId, row('newest').project?.id);
  });

  test(
    'canonical title publishes while an older catalog read is held',
    () async {
      final chat = (await controller.openSession(key('newest')))!;
      await settleCatalog();
      final held = Completer<void>();
      host.pageDelays[('personal', 0)] = held;
      addTearDown(() {
        if (!held.isCompleted) held.complete();
      });
      final refresh = data.refresh(archivedOnly: false);
      await Future<void>.delayed(Duration.zero);
      emitChatEvent(controller, chat, 'session.title', {
        'session_id': 'newest',
        'title': 'Plan Cairns flights',
      });
      expect(chat.title, 'Plan Cairns flights');
      expect(row('newest').title, chat.title);
      expect(data.project('cairns').entries.map((entry) => entry.id), [
        'newest',
      ]);

      host.changes['personal'] = {
        'newest': {'title': 'Plan Cairns flights'},
      };
      held.complete();
      await refresh;
      expect(row('newest').title, chat.title);
      expect(
        host.updates,
        isEmpty,
        reason: 'Observations never rename on Hermes',
      );
    },
  );

  test(
    'catalog signals during a held read request fresh project membership',
    () async {
      final held = Completer<void>();
      host.pageDelays[('personal', 0)] = held;
      addTearDown(() {
        if (!held.isCompleted) held.complete();
      });
      final refresh = data.refresh(archivedOnly: false);
      await Future<void>.delayed(Duration.zero);
      host.changes['personal'] = {
        'newest': {'title': 'Plan Cairns flights', 'cwd': '/Mobile app'},
      };
      catalogChanged();
      catalogChanged();
      held.complete();
      await refresh;
      expect(row('newest').title, 'Plan Cairns flights');
      expect(row('newest').project?.id, 'p2');
      expect(host.updates, isEmpty);
      expect(host.moves, isEmpty);
    },
  );

  test('inactive browser defers catalog signals until it resumes', () async {
    data.setReadActive(false);
    final reads = host.reads.length;
    host.changes['personal'] = {
      'newest': {'title': 'Plan Cairns flights', 'cwd': '/Mobile app'},
    };
    catalogChanged();
    await settleCatalog();
    expect(host.reads.length, reads);
    expect(row('newest').title, isNot('Plan Cairns flights'));
    data.setReadActive(true);
    await settleCatalog();
    expect(row('newest').title, 'Plan Cairns flights');
    expect(row('newest').project?.id, 'p2');
  });

  test(
    'catalog metadata updates preserve order until explicit refresh',
    () async {
      await data.chooseView(
        const BrowserPreferenceIntent.grouping(ChatGrouping.profile),
      );
      List<String> order() => data
          .project('')
          .groups
          .singleWhere((group) => group.key == 'personal')
          .entries
          .map((entry) => entry.id)
          .toList();
      final before = order();
      host.changes['personal'] = {
        'extra-100': {
          'last_active': host.now + 100,
          'title': 'Plan Cairns flights',
        },
      };
      catalogChanged();
      await settleCatalog();
      expect(row('extra-100').title, 'Plan Cairns flights');
      expect(order(), before);
      await data.refresh(archivedOnly: false);
      expect(order().indexOf('extra-100'), lessThan(order().indexOf('newest')));
    },
  );

  Future<void> restart({bool alreadyDisposed = false}) async {
    data.dispose();
    if (!alreadyDisposed) controller.dispose();
    await Future<void>.delayed(Duration.zero);
    final persisted = await platform.getAll();
    SharedPreferences.setMockInitialValues({
      for (final entry in persisted.entries)
        entry.key.substring('flutter.'.length): entry.value,
    });
    preferences = await SharedPreferences.getInstance();
    drafts = _FailingDraftStore(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'host',
          label: 'Test',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'mutations',
      preferences: preferences,
      appPreferences: appPreferences,
      draftStore: drafts,
      attachmentService: attachments,
      gatewayFactory: host.gateway,
    );
    data = ChatBrowserData(controller);
    await controller.initialize();
  }

  Future<ProfileSessionKey> prepareKeptWork() async {
    final target = key('newest');
    await controller.openSession(target);
    await restoreComposerFixture(
      chat: controller.current!.chat!,
      preferences: controller.preferences,
      appendQueued: [QueuedPromptDraft(text: 'Retained queue')],
    );
    await controller.current!.chat!.composer.pause();
    await controller.updateDraft(controller.current!.chat!, 'Retained draft');
    host.failMutation = true;
    await expectLater(
      controller.mutateSession(target, delete: true, canDispatch: () => true),
      throwsStateError,
    );
    host.failMutation = false;
    return target;
  }

  DeletedDraftCleanupEntry recoveryEntry(ProfileSessionKey target) => controller
      .deletedDraftCleanupPresentation
      .value
      .entries
      .singleWhere((entry) => entry.key == target);

  test(
    'explicit keep saves retirement before restoring retained work',
    () async {
      final target = await prepareKeptWork();
      expect(recoveryEntry(target).actions.map((a) => a.label), ['Check chat']);
      await controller.inspectDeletedDraftCleanup(target);
      expect(recoveryEntry(target).actions.map((a) => a.label), [
        'Check chat',
        'Keep chat',
      ]);
      final wireBefore = host.wireCalls.length;
      final deletesBefore = host.deletes.length;
      platform.holdRetirement = Completer<void>();
      platform.retirementStarted = Completer<void>();
      final gate = platform.holdRetirement!;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final keeping = controller.keepPreparedSession(target);
      await platform.retirementStarted!.future;
      expect(controller.current!.quarantinedSessions, contains('newest'));
      expect(journal().receipt('personal', 'newest'), isNotNull);
      expect(recoveryEntry(target).busy, isTrue);
      expect(recoveryEntry(target).actions, isEmpty);
      expect(drafts.clearAttempts, 0);
      gate.complete();
      await keeping;
      expect(
        controller.current!.quarantinedSessions,
        isNot(contains('newest')),
      );
      expect(journal().receipt('personal', 'newest'), isNull);
      expect(controller.deletedDraftCleanupPresentation.value.entries, isEmpty);
      expect(
        host.wireCalls.length,
        wireBefore,
        reason: 'Keep sends no prompt/resume',
      );
      expect(
        host.deletes.length,
        deletesBefore,
        reason: 'Keep repeats no DELETE',
      );
      final kept = (await controller.savedDraft(target))!;
      expect(kept.text, 'Retained draft');
      expect(kept.queuedPrompts.single.text, 'Retained queue');
      expect(kept.queuePaused, isTrue);
      await restart();
      expect(controller.current!.quarantinedSessions, isEmpty);
      expect(journal().receipt('personal', 'newest'), isNull);
      expect((await controller.savedDraft(target))!.text, 'Retained draft');
    },
  );

  test(
    'failed keep retirement remains durable and owner publishes error',
    () async {
      final target = await prepareKeptWork();
      await controller.inspectDeletedDraftCleanup(target);
      platform.failRetirement = true;
      recoveryEntry(
        target,
      ).actions.singleWhere((a) => a.label == 'Keep chat').invoke();
      for (var n = 0; n < 100 && recoveryEntry(target).error == null; n++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(recoveryEntry(target).error, isNotNull);
      expect(recoveryEntry(target).busy, isFalse);
      expect(controller.current!.quarantinedSessions, contains('newest'));
      expect(journal().receipt('personal', 'newest')!.confirmed, isFalse);
      expect(drafts.clearAttempts, 0);
      await restart();
      expect(controller.current!.quarantinedSessions, contains('newest'));
      expect(
        (await drafts.read(profileName: 'personal', sessionId: 'newest'))!.text,
        'Retained draft',
      );
    },
  );

  for (final unavailable in [false, true]) {
    test(
      'Keep rechecks ${unavailable ? 'unavailable' : 'absent'} presence without cleanup',
      () async {
        final target = await prepareKeptWork();
        await controller.inspectDeletedDraftCleanup(target);
        if (unavailable) {
          host.failPresence = true;
        } else {
          host.removed.putIfAbsent('personal', () => {}).add('newest');
        }
        final wireBefore = host.wireCalls.length;
        await expectLater(
          controller.keepPreparedSession(target),
          throwsStateError,
        );
        expect(journal().receipt('personal', 'newest')!.confirmed, isFalse);
        expect(controller.current!.quarantinedSessions, contains('newest'));
        expect(drafts.clearAttempts, 0);
        expect(host.wireCalls.length, wireBefore);
        expect(recoveryEntry(target).actions.map((a) => a.label), [
          'Check chat',
        ]);
      },
    );
  }

  test(
    'Keep closing during held verification preserves prepared receipt',
    () async {
      final target = await prepareKeptWork();
      host.presenceStarted = Completer<void>();
      host.presenceDelay = Completer<void>();
      final gate = host.presenceDelay!;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final keeping = controller.keepPreparedSession(target);
      await host.presenceStarted!.future;
      controller.dispose();
      gate.complete();
      await keeping;
      expect(journal().receipt('personal', 'newest')!.confirmed, isFalse);
      expect(drafts.clearAttempts, 0);
      await restart(alreadyDisposed: true);
      expect(controller.current!.quarantinedSessions, contains('newest'));
    },
  );

  test(
    'a stale Keep callback cannot retire a subsequent prepared deletion',
    () async {
      final target = await prepareKeptWork();
      await controller.inspectDeletedDraftCleanup(target);
      final stale = recoveryEntry(
        target,
      ).actions.singleWhere((a) => a.label == 'Keep chat');
      await controller.keepPreparedSession(target);
      await prepareKeptWork();
      final next = journal().receipt('personal', 'newest');
      final readsBefore = host.presenceReads;
      stale.invoke();
      await Future<void>.delayed(Duration.zero);
      expect(journal().receipt('personal', 'newest'), same(next));
      expect(host.presenceReads, readsBefore);
      expect(controller.current!.quarantinedSessions, contains('newest'));
    },
  );

  test('known ACK cannot offer Keep even when ACK journaling failed', () async {
    await controller.openSession(key('newest'));
    await controller.updateDraft(controller.current!.chat!, 'ACK local work');
    platform.failPhase = 'acknowledged';
    await expectLater(
      controller.mutateSession(
        key('newest'),
        delete: true,
        canDispatch: () => true,
      ),
      throwsStateError,
    );
    expect(journal().receipt('personal', 'newest')!.confirmed, isFalse);
    expect(recoveryEntry(key('newest')).actions.map((a) => a.label), [
      'Retry cleanup',
    ]);
    await expectLater(
      controller.keepPreparedSession(key('newest')),
      throwsStateError,
    );
    expect(journal().receipt('personal', 'newest'), isNotNull);
    expect(controller.current!.deletedSessions, contains('newest'));
  });

  testWidgets('unrelated streaming does not republish unchanged recovery facts', (
    tester,
  ) async {
    final target = await prepareKeptWork();
    host.resumeRuntimeIds['old'] = 'old-stream-runtime';
    await controller.openSession(key('old'));
    final streaming = controller.current!.chat!;
    expect(streaming.runtime.runtimeId, 'old-stream-runtime');
    expect(streaming.key, key('old'));
    final streamGateway = controller.current!.gateway;
    await tester.pump();
    final before = controller.deletedDraftCleanupPresentation.value;
    var publications = 0;
    var workspaceChanges = 0;
    void recoveryChanged() => publications++;
    void workspaceChanged() => workspaceChanges++;
    controller.deletedDraftCleanupPresentation.addListener(recoveryChanged);
    controller.addListener(workspaceChanged);
    addTearDown(() {
      controller.deletedDraftCleanupPresentation.removeListener(
        recoveryChanged,
      );
      controller.removeListener(workspaceChanged);
    });
    host.event(streamGateway, streaming.runtime.runtimeId, 'message.start', {
      'turn_id': 'unrelated-recovery-turn',
    });
    for (var n = 0; n < 5; n++) {
      host.event(streamGateway, streaming.runtime.runtimeId, 'message.delta', {
        'turn_id': 'unrelated-recovery-turn',
        'segment': 0,
        'offset': n,
        'text': '$n',
      });
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(streaming.reading.streaming, '01234');
    expect(
      workspaceChanges,
      greaterThan(0),
      reason: 'real stream publication occurred',
    );
    expect(journal().receipt('personal', 'newest')!.confirmed, isFalse);
    expect(recoveryEntry(target).actions.map((a) => a.label), ['Check chat']);
    expect(
      publications,
      0,
      reason:
          'unchanged recovery should not rebuild beside another streamed answer',
    );
    expect(controller.deletedDraftCleanupPresentation.value, same(before));
  });

  test(
    'an equivalent replaced receipt publishes fresh usable callbacks',
    () async {
      final target = key('newest');
      await controller.openSession(target);
      await controller.updateDraft(
        controller.current!.chat!,
        'Confirmed cleanup',
      );
      platform.failPhase = 'completed';
      await expectLater(
        controller.mutateSession(target, delete: true, canDispatch: () => true),
        throwsStateError,
      );
      final before = controller.deletedDraftCleanupPresentation.value;
      final oldCallback = recoveryEntry(target).actions.single;
      final oldReceipt = journal().receipt('personal', 'newest')!;
      final replacement = await journal().acknowledge(
        profile: 'personal',
        session: 'newest',
        files: oldReceipt.files,
      );
      expect(replacement, isNot(same(oldReceipt)));
      await controller.mutateSession(
        key('old'),
        changes: {'pinned': true},
        canDispatch: () => true,
      );
      final after = controller.deletedDraftCleanupPresentation.value;
      expect(
        after,
        isNot(same(before)),
        reason: 'same display facts require new captured-receipt authority',
      );
      platform.failPhase = null;
      oldCallback.invoke();
      await Future<void>.delayed(Duration.zero);
      expect(
        journal().receipt('personal', 'newest')!.phase,
        DeletedDraftCleanupPhase.acknowledged,
      );
      recoveryEntry(target).actions.single.invoke();
      for (
        var n = 0;
        n < 100 &&
            controller.deletedDraftCleanupPresentation.value.entries.isNotEmpty;
        n++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        journal().receipt('personal', 'newest')!.phase,
        DeletedDraftCleanupPhase.completed,
      );
      expect(controller.deletedDraftCleanupPresentation.value.entries, isEmpty);
      expect(host.deletes, hasLength(1));
    },
  );

  test(
    'confirmed cleanup callback does not claim cleared work was kept',
    () async {
      final target = key('newest');
      await controller.openSession(target);
      await controller.updateDraft(
        controller.current!.chat!,
        'Cleared after ACK',
      );
      platform.failPhase = 'completed';
      await expectLater(
        controller.mutateSession(target, delete: true, canDispatch: () => true),
        throwsStateError,
      );
      recoveryEntry(target).actions.single.invoke();
      for (var n = 0; n < 100 && recoveryEntry(target).error == null; n++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        await drafts.read(profileName: 'personal', sessionId: 'newest'),
        isNull,
      );
      expect(journal().receipt('personal', 'newest')!.confirmed, isTrue);
      expect(host.deletes, hasLength(1));
      expect(recoveryEntry(target).error, isNot(contains('work is kept')));
      expect(recoveryEntry(target).error, contains('local'));
    },
  );

  test('failed prepare never dispatches and keeps draft', () async {
    await controller.openSession(key('newest'));
    await controller.updateDraft(controller.current!.chat!, 'Do not lose this');
    final rpcBefore = host.calls.length;
    platform.failPhase = 'prepared';
    await expectLater(
      controller.mutateSession(
        key('newest'),
        delete: true,
        canDispatch: () => true,
      ),
      throwsStateError,
    );
    expect(
      host.calls.length,
      rpcBefore,
      reason: 'durable prepare precedes all server operations',
    );
    expect(host.deletes, isEmpty);
    expect(journal().receipts, isEmpty);
    expect(await controller.savedDraft(key('newest')), isNotNull);
  });

  for (final unavailable in [false, true]) {
    test(
      'prepared restart stays inert when presence is ${unavailable ? 'unavailable' : 'present'}',
      () async {
        await controller.openSession(key('newest'));
        await restoreComposerFixture(
          chat: controller.current!.chat!,
          preferences: controller.preferences,
          appendQueued: [QueuedPromptDraft(text: 'Kept queue')],
        );
        await controller.updateDraft(
          controller.current!.chat!,
          'Retained uncertain work',
        );
        host.failMutation = true;
        await expectLater(
          controller.mutateSession(
            key('newest'),
            delete: true,
            canDispatch: () => true,
          ),
          throwsStateError,
        );
        host.failMutation = false;
        host.failPresence = unavailable;
        final resumeBefore = host.calls
            .where((call) => call.$2 == 'session.resume')
            .length;
        await restart();
        expect(controller.current!.quarantinedSessions, contains('newest'));
        expect(controller.current!.deletedSessions, isNot(contains('newest')));
        expect(
          journal().receipt('personal', 'newest')!.phase,
          DeletedDraftCleanupPhase.prepared,
        );
        expect(
          (await drafts.read(
            profileName: 'personal',
            sessionId: 'newest',
          ))!.text,
          'Retained uncertain work',
        );
        expect(
          controller
              .savedDrafts(controller.current!.scope)
              .where((d) => d.sessionId == 'newest'),
          isEmpty,
        );
        await expectLater(
          controller.openSession(key('newest')),
          throwsStateError,
        );
        await expectLater(
          controller.mutateSession(
            key('newest'),
            delete: true,
            canDispatch: () => true,
          ),
          throwsStateError,
        );
        expect(host.deletes, isEmpty);
        expect(
          host.calls.where((call) => call.$2 == 'session.resume').length,
          resumeBefore,
        );
      },
    );
  }

  test(
    'failed ACK journal keeps prepared recovery without destructive cleanup',
    () async {
      await controller.openSession(key('newest'));
      await controller.updateDraft(
        controller.current!.chat!,
        'ACK was received',
      );
      platform.failPhase = 'acknowledged';
      await expectLater(
        controller.mutateSession(
          key('newest'),
          delete: true,
          canDispatch: () => true,
        ),
        throwsStateError,
      );
      expect(controller.current!.deletedSessions, contains('newest'));
      expect(drafts.clearAttempts, 0);
      expect(
        journal().receipt('personal', 'newest')!.phase,
        DeletedDraftCleanupPhase.prepared,
      );
      host.failPresence = true;
      await restart();
      expect(controller.current!.quarantinedSessions, contains('newest'));
      expect(
        (await drafts.read(profileName: 'personal', sessionId: 'newest'))!.text,
        'ACK was received',
      );
      expect(host.deletes, hasLength(1));
      host.failPresence = false;
      await controller.mutateSession(
        key('newest'),
        delete: true,
        canDispatch: () => true,
      );
      expect(host.deletes, hasLength(1));
      expect(
        await drafts.read(profileName: 'personal', sessionId: 'newest'),
        isNull,
      );
      expect(
        journal().receipt('personal', 'newest')!.phase,
        DeletedDraftCleanupPhase.completed,
      );
    },
  );

  test(
    'failed completion retains ACK receipt and restart is local only',
    () async {
      await controller.openSession(key('newest'));
      await controller.updateDraft(
        controller.current!.chat!,
        'Clear once acknowledged',
      );
      platform.failPhase = 'completed';
      await expectLater(
        controller.mutateSession(
          key('newest'),
          delete: true,
          canDispatch: () => true,
        ),
        throwsStateError,
      );
      expect(
        journal().receipt('personal', 'newest')!.phase,
        DeletedDraftCleanupPhase.acknowledged,
      );
      final readsBefore = host.presenceReads;
      await restart();
      expect(
        host.presenceReads,
        readsBefore,
        reason: 'confirmed receipts need no server observation',
      );
      expect(host.deletes, hasLength(1));
      expect(
        journal().receipt('personal', 'newest')!.phase,
        DeletedDraftCleanupPhase.completed,
      );
    },
  );

  test(
    'invalid restored file path keeps receipt and work without deleting outside cache',
    () async {
      final outside = await File(
        '${managedCache.parent.path}/outside-wing-${DateTime.now().microsecondsSinceEpoch}',
      ).writeAsString('x');
      addTearDown(() async {
        if (await outside.exists()) await outside.delete();
      });
      await controller.openSession(key('newest'));
      final chat = controller.current!.chat!;
      await restoreComposerFixture(
        chat: chat,
        preferences: controller.preferences,
        appendAttachments: [
          AttachmentDraft(
            id: 'draft-1-0.bin',
            cachedPath: outside.path,
            name: 'file.txt',
            byteLength: 1,
            mediaType: 'text/plain',
            kind: AttachmentDraftKind.genericFile,
          ),
        ],
      );
      await controller.updateDraft(chat, 'Keep metadata for inspection');
      await expectLater(
        controller.mutateSession(
          key('newest'),
          delete: true,
          canDispatch: () => true,
        ),
        throwsStateError,
      );
      expect(drafts.clearAttempts, 0);
      expect(await outside.exists(), isTrue);
      final presenceBefore = host.presenceReads;
      await restart();
      expect(
        host.presenceReads,
        presenceBefore,
        reason: 'invalid file cannot erase a confirmed ACK',
      );
      expect(await outside.exists(), isTrue);
      expect(
        journal().receipt('personal', 'newest')!.phase,
        DeletedDraftCleanupPhase.acknowledged,
      );
      expect(
        (await drafts.read(profileName: 'personal', sessionId: 'newest'))!.text,
        'Keep metadata for inspection',
      );
      expect(host.deletes, hasLength(1));
    },
  );

  test('ACK publishes before held journal I/O and draft clearing', () async {
    await controller.openSession(key('newest'));
    await controller.updateDraft(controller.current!.chat!, 'Held ACK receipt');
    platform.holdPhase = 'acknowledged';
    platform.writeStarted = Completer<void>();
    platform.writeDelay = Completer<void>();
    final delay = platform.writeDelay!;
    addTearDown(() {
      if (!delay.isCompleted) delay.complete();
    });
    final deleting = controller.mutateSession(
      key('newest'),
      delete: true,
      canDispatch: () => true,
    );
    await platform.writeStarted!.future;
    expect(controller.current!.deletedSessions, contains('newest'));
    expect(controller.current!.selectedSession, isNull);
    expect(
      data.entries.where((entry) => entry.sessionKey == key('newest')),
      isEmpty,
    );
    expect(
      data.entries.any(
        (entry) =>
            entry.sessionKey.sessionId == 'newest' &&
            entry.sessionKey.workspace.profileName != 'personal',
      ),
      isTrue,
    );
    expect(drafts.clearAttempts, 0);
    expect(
      journal().receipt('personal', 'newest')!.phase,
      DeletedDraftCleanupPhase.prepared,
    );
    delay.complete();
    await deleting;
    expect(
      journal().receipt('personal', 'newest')!.phase,
      DeletedDraftCleanupPhase.completed,
    );
  });

  test(
    'disposal during held prepare prevents every new server operation',
    () async {
      await controller.openSession(key('newest'));
      await controller.updateDraft(
        controller.current!.chat!,
        'Prepared but never sent',
      );
      final target = key('newest');
      platform.holdPhase = 'prepared';
      platform.writeStarted = Completer<void>();
      platform.writeDelay = Completer<void>();
      final delay = platform.writeDelay!;
      addTearDown(() {
        if (!delay.isCompleted) delay.complete();
      });
      final rpcBefore = host.calls.length;
      final deleting = controller.mutateSession(
        target,
        delete: true,
        canDispatch: () => true,
      );
      await platform.writeStarted!.future;
      controller.dispose();
      Object? secondFailure;
      try {
        await controller.mutateSession(
          target,
          delete: true,
          canDispatch: () => true,
        );
      } catch (failure) {
        secondFailure = failure;
      }
      delay.complete();
      Object? pendingFailure;
      try {
        await deleting;
      } catch (failure) {
        pendingFailure = failure;
      }
      final rpcAfter = host.calls.length;
      final deletesAfter = host.deletes.length;
      await restart(alreadyDisposed: true);
      expect(
        secondFailure,
        isA<StateError>(),
        reason: 'closed owner refuses new actions',
      );
      expect(
        pendingFailure,
        isA<StateError>(),
        reason: 'closure before dispatch refuses the pending action',
      );
      expect(rpcAfter, rpcBefore);
      expect(deletesAfter, 0);
      expect(
        journal().receipt('personal', 'newest')!.phase,
        DeletedDraftCleanupPhase.prepared,
      );
      expect(controller.current!.quarantinedSessions, contains('newest'));
      expect(
        (await drafts.read(profileName: 'personal', sessionId: 'newest'))!.text,
        'Prepared but never sent',
      );
    },
  );

  test(
    'ACK arriving after controller disposal still journals local cleanup',
    () async {
      await controller.openSession(key('newest'));
      await controller.updateDraft(
        controller.current!.chat!,
        'Closed during dispatch',
      );
      host.deleteAcknowledged = Completer<void>();
      host.deleteAckDelay = Completer<void>();
      final delay = host.deleteAckDelay!;
      addTearDown(() {
        if (!delay.isCompleted) delay.complete();
      });
      final deleting = controller.mutateSession(
        key('newest'),
        delete: true,
        canDispatch: () => true,
      );
      await host.deleteAcknowledged!.future;
      controller.dispose();
      delay.complete();
      await deleting;
      expect(
        journal().receipt('personal', 'newest')!.phase,
        DeletedDraftCleanupPhase.completed,
      );
      expect(
        await drafts.read(profileName: 'personal', sessionId: 'newest'),
        isNull,
      );
      expect(host.deletes, hasLength(1));
      await restart(alreadyDisposed: true);
      expect(controller.current!.deletedSessions, contains('newest'));
      expect(host.deletes, hasLength(1));
    },
  );

  test(
    'missing managed directory is idempotent for legitimate captured files',
    () async {
      final source = await File(
        '${managedCache.parent.path}/wing-missing-source-${DateTime.now().microsecondsSinceEpoch}',
      ).writeAsString('x');
      addTearDown(() async {
        if (await source.exists()) await source.delete();
      });
      final file = await attachments.prepareGenericFile(
        sourcePath: source.path,
        displayName: 'file.txt',
        existingDrafts: const [],
      );
      await controller.openSession(key('newest'));
      await restoreComposerFixture(
        chat: controller.current!.chat!,
        preferences: controller.preferences,
        appendAttachments: [file],
      );
      await controller.updateDraft(
        controller.current!.chat!,
        'Missing bytes do not block cleanup',
      );
      await managedCache.delete(recursive: true);
      await controller.mutateSession(
        key('newest'),
        delete: true,
        canDispatch: () => true,
      );
      expect(
        await drafts.read(profileName: 'personal', sessionId: 'newest'),
        isNull,
      );
      expect(
        journal().receipt('personal', 'newest')!.phase,
        DeletedDraftCleanupPhase.completed,
      );
      expect(
        await managedCache.exists(),
        isFalse,
        reason: 'cleanup does not recreate a missing cache',
      );
      expect(host.deletes, hasLength(1));
    },
  );

  test(
    'symlink cleanup metadata preserves outside target and local draft',
    () async {
      final outside = await File(
        '${managedCache.parent.path}/wing-link-target-${DateTime.now().microsecondsSinceEpoch}',
      ).writeAsString('x');
      addTearDown(() async {
        if (await outside.exists()) await outside.delete();
      });
      final link = Link('${managedCache.path}/draft-1-0.bin');
      await link.create(outside.path);
      await controller.openSession(key('newest'));
      final chat = controller.current!.chat!;
      await restoreComposerFixture(
        chat: chat,
        preferences: controller.preferences,
        appendAttachments: [
          AttachmentDraft(
            id: 'draft-1-0.bin',
            cachedPath: link.path,
            name: 'file.txt',
            byteLength: 1,
            mediaType: 'text/plain',
            kind: AttachmentDraftKind.genericFile,
          ),
        ],
      );
      await controller.updateDraft(chat, 'Keep symlink receipt');
      await expectLater(
        controller.mutateSession(
          key('newest'),
          delete: true,
          canDispatch: () => true,
        ),
        throwsStateError,
      );
      expect(drafts.clearAttempts, 0);
      expect(await outside.exists(), isTrue);
      expect(
        await FileSystemEntity.type(link.path, followLinks: false),
        FileSystemEntityType.link,
      );
      expect(
        (await drafts.read(profileName: 'personal', sessionId: 'newest'))!.text,
        'Keep symlink receipt',
      );
    },
  );

  test(
    'completed receipts are retained; admission refuses before dispatch',
    () async {
      final store = journal();
      for (var i = 0; i < DeletedDraftCleanupStore.maximumReceipts; i++) {
        final id = 'completed-$i';
        await store.prepare(profile: 'personal', session: id, files: const []);
        await store.acknowledge(
          profile: 'personal',
          session: id,
          files: const [],
        );
        await store.complete('personal', id);
      }
      final before = host.calls.length;
      await expectLater(
        controller.mutateSession(
          key('newest'),
          delete: true,
          canDispatch: () => true,
        ),
        throwsStateError,
      );
      expect(host.calls.length, before);
      expect(host.deletes, isEmpty);
      expect(
        store.receipts,
        hasLength(DeletedDraftCleanupStore.maximumReceipts),
      );
      expect(
        store.receipts.every(
          (r) => r.phase == DeletedDraftCleanupPhase.completed,
        ),
        isTrue,
      );
    },
  );

  test(
    'stale prepared chat callbacks keep work and dispatch no prompt or command',
    () async {
      await controller.openSession(key('newest'));
      final chat = controller.current!.chat!;
      await controller.updateDraft(chat, 'Retained prepared composer');
      host.failMutation = true;
      await expectLater(
        controller.mutateSession(
          key('newest'),
          delete: true,
          canDispatch: () => true,
        ),
        throwsStateError,
      );
      host.failMutation = false;
      final before = host.wireCalls.length;
      final failures = <Object?>[];
      for (final operation in <Future<Object?> Function()>[
        () => controller.send(chat),
        () async {
          await controller.queuePrompt(chat, 'Late queued mutation');
          return null;
        },
        () async {
          await controller.resumeQueue(chat);
          return null;
        },
      ]) {
        Object? failure;
        try {
          await operation();
        } catch (error) {
          failure = error;
        }
        failures.add(failure);
      }
      expect(
        host.wireCalls.length,
        before,
        reason: 'blocked callbacks send no physical request',
      );
      expect(chat.composer.observation.text, 'Retained prepared composer');
      expect(chat.composer.observation.queue, isEmpty);
      expect(
        (await drafts.read(profileName: 'personal', sessionId: 'newest'))!.text,
        'Retained prepared composer',
      );
      expect(failures.every((failure) => failure is StateError), isTrue);
      // Passive UI provisioning remains usable until the route is replaced.
      expect(() => controller.chatProjectLabel(chat), returnsNormally);
      expect(() => controller.parentSessionId(chat), returnsNormally);
    },
  );

  test(
    'stale prepared queue callback cannot change the durable outbox',
    () async {
      await controller.openSession(key('newest'));
      final chat = controller.current!.chat!;
      await controller.updateDraft(chat, 'Original kept composer');
      host.failMutation = true;
      await expectLater(
        controller.mutateSession(
          key('newest'),
          delete: true,
          canDispatch: () => true,
        ),
        throwsStateError,
      );
      host.failMutation = false;
      await chat.composer.pause();
      Object? failure;
      try {
        await controller.queuePrompt(chat, 'Forbidden late queue item');
      } catch (error) {
        failure = error;
      }
      final stored = await drafts.read(
        profileName: 'personal',
        sessionId: 'newest',
      );
      expect(
        chat.composer.observation.queue,
        isEmpty,
        reason: 'quarantine preserves in-memory work',
      );
      expect(
        stored!.queuedPrompts,
        isEmpty,
        reason: 'quarantine preserves durable work',
      );
      expect(stored.text, 'Original kept composer');
      expect(failure, isA<StateError>());
    },
  );

  test(
    'prepared deletion fences a command after its held catalog read',
    () async {
      await controller.openSession(key('newest'));
      final chat = controller.current!.chat!;
      await controller.updateDraft(chat, '/custom');
      final held = Completer<void>();
      addTearDown(() {
        if (!held.isCompleted) held.complete();
      });
      host.rpcDelays['commands.catalog'] = held;
      host.rpcStarted['commands.catalog'] = Completer<void>();
      final sending = controller.send(chat);
      await host.rpcStarted['commands.catalog']!.future;
      host.failMutation = true;
      await expectLater(
        controller.mutateSession(
          key('newest'),
          delete: true,
          canDispatch: () => true,
        ),
        throwsStateError,
      );
      host.failMutation = false;
      held.complete();
      await sending;
      expect(
        host.wireCalls.where(
          (method) => method == 'command.dispatch' || method == 'slash.exec',
        ),
        isEmpty,
      );
      expect(chat.composer.observation.text, '/custom');
      expect(
        (await drafts.read(profileName: 'personal', sessionId: 'newest'))!.text,
        '/custom',
      );
    },
  );

  test(
    'acknowledged deletion cannot be recreated by a late command draft save',
    () async {
      final target = key('newest');
      await controller.openSession(target);
      final chat = controller.current!.chat!;
      await controller.updateDraft(chat, '/custom');
      final held = Completer<void>();
      addTearDown(() {
        if (!held.isCompleted) held.complete();
      });
      host.rpcDelays['commands.catalog'] = held;
      host.rpcStarted['commands.catalog'] = Completer<void>();
      final sending = controller.send(chat);
      await host.rpcStarted['commands.catalog']!.future;
      await controller.mutateSession(
        target,
        delete: true,
        canDispatch: () => true,
      );
      expect(
        await drafts.read(profileName: 'personal', sessionId: 'newest'),
        isNull,
      );
      expect(
        journal().receipt('personal', 'newest')!.phase,
        DeletedDraftCleanupPhase.completed,
      );
      held.complete();
      await sending;
      expect(
        host.wireCalls.where(
          (method) => method == 'command.dispatch' || method == 'slash.exec',
        ),
        isEmpty,
      );
      expect(host.deletes, hasLength(1));
      expect(
        await drafts.read(profileName: 'personal', sessionId: 'newest'),
        isNull,
        reason:
            'a late no-dispatch finalizer cannot recreate acknowledged deleted work',
      );
      await restart();
      expect(
        await drafts.read(profileName: 'personal', sessionId: 'newest'),
        isNull,
      );
      expect(controller.current!.deletedSessions, contains('newest'));
      expect(host.deletes, hasLength(1));
    },
  );

  test(
    'prepared deletion leaves a held queue resume inert without clearing work',
    () async {
      await controller.openSession(key('newest'));
      final chat = controller.current!.chat!;
      await restoreComposerFixture(
        chat: chat,
        preferences: controller.preferences,
        appendQueued: [QueuedPromptDraft(text: 'Preserved queued request')],
      );
      await chat.composer.pause();
      await controller.updateDraft(chat, 'Fresh composer');
      final held = Completer<void>();
      addTearDown(() {
        if (!held.isCompleted) held.complete();
      });
      host.rpcDelays['session.resume'] = held;
      host.rpcStarted['session.resume'] = Completer<void>();
      final resuming = controller.resumeQueue(chat);
      await host.rpcStarted['session.resume']!.future;
      host.active =
          false; // Server now reports no live runtime, as close/expiry may do.
      host.failMutation = true;
      await expectLater(
        controller.mutateSession(
          key('newest'),
          delete: true,
          canDispatch: () => true,
        ),
        throwsStateError,
      );
      host.failMutation = false;
      held.complete();
      await resuming;
      expect(
        host.wireCalls.where((method) => method == 'prompt.submit'),
        isEmpty,
      );
      expect(chat.composer.observation.paused, isTrue);
      expect(
        chat.composer.observation.queue.single.text,
        'Preserved queued request',
      );
      expect(
        (await drafts.read(
          profileName: 'personal',
          sessionId: 'newest',
        ))!.queuedPrompts.single.text,
        'Preserved queued request',
      );
    },
  );

  test(
    'closure during an acknowledged upload prevents later physical prompt dispatch',
    () async {
      final source = await File(
        '${managedCache.parent.path}/wing-upload-close-${DateTime.now().microsecondsSinceEpoch}',
      ).writeAsString('x');
      addTearDown(() async {
        if (await source.exists()) await source.delete();
      });
      final staged = await attachments.prepareGenericFile(
        sourcePath: source.path,
        displayName: 'upload.txt',
        existingDrafts: const [],
      );
      await controller.openSession(key('newest'));
      final chat = controller.current!.chat!;
      await restoreComposerFixture(
        chat: chat,
        preferences: controller.preferences,
        appendAttachments: [staged],
      );
      await controller.updateDraft(chat, 'Keep after uploaded bytes');
      final held = Completer<void>();
      addTearDown(() {
        if (!held.isCompleted) held.complete();
      });
      host.rpcDelays['file.attach'] = held;
      host.rpcStarted['file.attach'] = Completer<void>();
      final sending = controller.send(chat);
      await host.rpcStarted['file.attach']!.future;
      controller.dispose();
      held.complete();
      await sending;
      final physicalPrompts = host.wireCalls
          .where((method) => method == 'prompt.submit')
          .length;
      final kept = await drafts.read(
        profileName: 'personal',
        sessionId: 'newest',
      );
      await restart(alreadyDisposed: true);
      expect(physicalPrompts, 0);
      expect(kept!.queuedPrompts.single.text, 'Keep after uploaded bytes');
      expect(kept.queuedPrompts.single.submissionUncertain, isFalse);
      expect(await File(staged.cachedPath).exists(), isTrue);
    },
  );

  test('confirmed deletion survives local cleanup failure and retry', () async {
    final target = key('newest');
    await controller.openSession(target);
    final chat = controller.current!.chat!;
    await controller.updateDraft(chat, 'Unsent local draft');
    drafts.failClear = true;
    await expectLater(
      controller.mutateSession(target, delete: true, canDispatch: () => true),
      throwsStateError,
    );

    expect(controller.current!.deletedSessions, contains('newest'));
    expect(controller.current!.chats, isNot(contains('newest')));
    expect(controller.current!.selectedSession, isNull);
    expect(data.entries.any((entry) => entry.sessionKey == target), isFalse);
    await expectLater(controller.openSession(target), throwsStateError);
    expect(host.deletes, hasLength(1));

    drafts.failClear = false;
    await controller.mutateSession(
      target,
      delete: true,
      canDispatch: () => true,
    );
    await data.refresh(archivedOnly: false);
    expect(host.deletes, hasLength(1), reason: 'only local cleanup is retried');
    expect(data.entries.any((entry) => entry.sessionKey == target), isFalse);
    expect(
      await drafts.read(profileName: 'personal', sessionId: 'newest'),
      isNull,
    );
  });

  test(
    'acknowledged cleanup resumes after a real preferences restart',
    () async {
      final target = key('newest');
      await controller.openSession(target);
      await controller.updateDraft(
        controller.current!.chat!,
        'Kept until cleanup',
      );
      drafts.failClear = true;
      await expectLater(
        controller.mutateSession(target, delete: true, canDispatch: () => true),
        throwsStateError,
      );
      data.dispose();
      controller.dispose();
      await Future<void>.delayed(Duration.zero);
      // A late older reading write must not defeat the durable deletion receipt.
      await WorkspaceSnapshotStore(preferences, 'mutations').write({
        'selected': 'personal',
        'profiles': [
          {
            'name': 'personal',
            'archived': false,
            'sessions': [
              {'id': 'newest', 'title': 'Old cached chat'},
            ],
            'projects': [],
            'chats': [
              {'id': 'newest', 'title': 'Old cached chat', 'messages': []},
            ],
          },
        ],
      });
      final durableValues = <String, Object>{
        for (final name in preferences.getKeys()) name: preferences.get(name)!,
      };
      SharedPreferences.setMockInitialValues(durableValues);
      preferences = await SharedPreferences.getInstance();
      drafts = _FailingDraftStore(preferences);
      controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: SavedConnection(
            id: 'host',
            label: 'Test',
            host: 'localhost',
            port: 1,
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'mutations',
        preferences: preferences,
        appPreferences: appPreferences,
        draftStore: drafts,
        attachmentService: attachments,
        gatewayFactory: host.gateway,
      );
      data = ChatBrowserData(controller);
      expect(
        controller.current!.chats,
        isNot(contains('newest')),
        reason: 'durable tombstones precede reading snapshot restoration',
      );
      await controller.initialize();
      expect(controller.current!.deletedSessions, contains('newest'));
      expect(
        await drafts.read(profileName: 'personal', sessionId: 'newest'),
        isNull,
      );
      expect(
        host.deletes,
        hasLength(1),
        reason: 'restart only retries local cleanup',
      );
      await expectLater(
        controller.openSession(key('newest')),
        throwsStateError,
      );
    },
  );

  test(
    'deletion waits for older draft writes and retries only attachment cleanup',
    () async {
      final directory = await Directory.systemTemp.createTemp('wing-delete-');
      addTearDown(() => directory.delete(recursive: true));
      final source = await File(
        '${directory.path}/staged.txt',
      ).writeAsString('x');
      final staged = await attachments.prepareGenericFile(
        sourcePath: source.path,
        displayName: 'staged.txt',
        existingDrafts: const [],
      );
      final file = File(staged.cachedPath);
      final target = key('newest');
      await controller.openSession(target);
      final chat = controller.current!.chat!;
      await restoreComposerFixture(
        chat: chat,
        preferences: controller.preferences,
        appendAttachments: [staged],
      );
      drafts
        ..heldText = 'Older pending draft'
        ..writeStarted = Completer<void>()
        ..writeDelay = Completer<void>();
      final writeDelay = drafts.writeDelay!;
      addTearDown(() {
        if (!writeDelay.isCompleted) writeDelay.complete();
      });
      final writing = controller.updateDraft(chat, 'Older pending draft');
      await drafts.writeStarted!.future;

      final published = Completer<void>();
      void changed() {
        if (controller.current!.deletedSessions.contains('newest') &&
            !published.isCompleted) {
          published.complete();
        }
      }

      controller.addListener(changed);
      addTearDown(() => controller.removeListener(changed));
      attachments.failRemove = true;
      final deleting = controller.mutateSession(
        target,
        delete: true,
        canDispatch: () => true,
      );
      final deletionFailure = expectLater(deleting, throwsStateError);
      await published.future;
      expect(host.deletes, hasLength(1));
      expect(controller.current!.chats, isNot(contains('newest')));
      expect(data.entries.any((entry) => entry.sessionKey == target), isFalse);
      expect(drafts.clearAttempts, 0, reason: 'the older write still owns I/O');
      expect(attachments.removeAttempts, isEmpty);

      writeDelay.complete();
      await writing;
      await deletionFailure;
      expect(
        await drafts.read(profileName: 'personal', sessionId: 'newest'),
        isNull,
      );
      expect(await file.exists(), isTrue, reason: 'attachment cleanup failed');
      expect(attachments.removeAttempts, [staged.id]);
      await expectLater(controller.openSession(target), throwsStateError);

      attachments.failRemove = false;
      await controller.mutateSession(
        target,
        delete: true,
        canDispatch: () => true,
      );
      expect(host.deletes, hasLength(1), reason: 'retry never repeats DELETE');
      expect(attachments.removeAttempts, [staged.id, staged.id]);
      expect(await file.exists(), isFalse);
      expect(
        await drafts.read(profileName: 'personal', sessionId: 'newest'),
        isNull,
        reason: 'the settled older write cannot recreate the draft',
      );
    },
  );

  test(
    'confirmed changes outside the owner page publish before background reads',
    () async {
      expect(
        controller.current!.sessions.any((r) => r['id'] == 'extra-100'),
        isFalse,
      );
      final gate = Completer<void>();
      host.pageDelays[('personal', 0)] = gate;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      await controller.mutateSession(
        key('extra-100'),
        changes: {'pinned': true},
        canDispatch: () => true,
      );
      expect(row('extra-100').pinned, isTrue);
      expect(row('extra-100').inputTokens, 1000);
      expect(data.hasCompleteSnapshot('personal'), isTrue);
      gate.complete();
      await data.refresh(archivedOnly: false);
      expect(row('extra-100').pinned, isTrue);
    },
  );

  test(
    'overlapping refreshes cannot roll back a newer confirmed action',
    () async {
      final gate = Completer<void>();
      host.pageDelays[('personal', 0)] = gate;
      final refresh = data.refresh(archivedOnly: false);
      await Future<void>.delayed(Duration.zero);
      await controller.mutateSession(
        key('newest'),
        changes: {'pinned': true},
        canDispatch: () => true,
      );
      await controller.mutateSession(
        key('newest'),
        changes: {'title': 'New title'},
        canDispatch: () => true,
      );
      final observations = <(Object?, Object?)>[];
      void changed() =>
          observations.add((row('newest').pinned, row('newest').title));
      data.addListener(changed);
      gate.complete();
      await refresh;
      data.removeListener(changed);
      expect(observations, isNotEmpty);
      expect(observations.every((r) => r == (true, 'New title')), isTrue);
      expect(
        host.updates,
        hasLength(2),
        reason: 'refreshes never replay writes',
      );
    },
  );

  test(
    'refresh failure retains confirmed changes and retry only rereads',
    () async {
      host.pageFailures.add(('personal', 0));
      await controller.mutateSession(
        key('extra-100'),
        changes: {'archived': true},
        canDispatch: () => true,
      );
      await data.refresh(archivedOnly: false);
      expect(
        data.entries.any((e) => e.sessionKey == key('extra-100')),
        isFalse,
      );
      expect(
        data.state.profiles['personal']?.error,
        contains('Could not refresh chats'),
      );
      expect(data.hasCompleteSnapshot('personal'), isTrue);
      host.pageFailures.clear();
      await data.refresh(archivedOnly: false);
      expect(
        data.state.profiles.values.where((profile) => profile.error != null),
        isEmpty,
      );
      expect(host.updates, hasLength(1));
      expect(
        data.entries.any((e) => e.sessionKey == key('extra-100')),
        isFalse,
      );
    },
  );

  test(
    'project edits, moves, creation and deletion use the same refresh lifecycle',
    () async {
      final gate = Completer<void>();
      host.projectReadDelay = gate;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final owner = controller.current!;
      await controller.updateProject(
        owner.scope,
        'p2',
        name: 'Renamed project',
        color: '#112233',
        canDispatch: () => true,
      );
      expect(
        data
            .filterChoices(BrowserFilter.project)
            .firstWhere((choice) => choice.id == 'personal/p2')
            .label,
        'Renamed project · personal',
      );
      await controller.moveSessionToProject(
        key('extra-100'),
        owner.projects.firstWhere((p) => p['id'] == 'p2'),
        canDispatch: () => true,
      );
      expect(
        data.entries
            .firstWhere((e) => e.sessionKey == key('extra-100'))
            .project!
            .name,
        'Renamed project',
      );
      await controller.createProject(
        'New project',
        '/new',
        color: '#112233',
        icon: 'folder',
        canDispatch: () => true,
      );
      expect(
        data
            .filterChoices(BrowserFilter.project)
            .any((choice) => choice.id == 'personal/created'),
        isTrue,
      );
      await controller.deleteProject(
        owner.scope,
        'p2',
        canDispatch: () => true,
      );
      expect(
        data
            .filterChoices(BrowserFilter.project)
            .any((choice) => choice.id == 'personal/p2'),
        isFalse,
      );
      expect(
        data.entries
            .firstWhere((e) => e.sessionKey == key('extra-100'))
            .project,
        isNull,
      );
      gate.complete();
      await data.refresh(archivedOnly: false);
      expect(
        data
            .filterChoices(BrowserFilter.project)
            .any((choice) => choice.id == 'personal/p2'),
        isFalse,
      );
      expect(
        data.state.profiles.values.where((profile) => profile.error != null),
        isEmpty,
      );
    },
  );

  test(
    'active message search remains available through mutation refresh',
    () async {
      await data.search('setup guide');
      expect(data.state.profiles['personal']?.searchMatches, contains('old'));
      final gate = Completer<void>();
      host.pageDelays[('personal', 0)] = gate;
      await controller.mutateSession(
        key('old'),
        changes: {'pinned': true},
        canDispatch: () => true,
      );
      expect(data.state.profiles['personal']?.searchMatches, contains('old'));
      gate.complete();
      await data.refresh(archivedOnly: false);
      expect(data.state.profiles['personal']?.searchMatches, contains('old'));
      expect(data.state.searching, isFalse);
    },
  );

  test('GUI log reads do not wait for held chat-list pages', () async {
    final gate = Completer<void>();
    host.pageDelays[('personal', 0)] = gate;
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final completed = Completer<void>();
    final read = host
        .gateway(controller.current!.scope)
        .completedToolActivities('runtime')
        .then((_) => completed.complete());
    await Future<void>.delayed(Duration.zero);
    expect(completed.isCompleted, isTrue);
    await read;
  });

  test(
    'unmodeled fixture reads fail instead of returning chat-list data',
    () async {
      await expectLater(
        host.gateway(controller.current!.scope).read('unmodeled-endpoint'),
        throwsStateError,
      );
    },
  );

  test(
    'new chats immediately acquire their confirmed project membership',
    () async {
      final gate = Completer<void>();
      host.pageDelays[('personal', 0)] = gate;
      final project = controller.current!.projects.firstWhere(
        (p) => p['id'] == 'p2',
      );
      final chat = await controller.createChat(
        inProject: project,
        canDispatch: () => true,
      );
      expect(
        data.entries
            .firstWhere((entry) => entry.sessionKey == chat.key)
            .project!
            .id,
        'p2',
      );
      gate.complete();
      await data.refresh(archivedOnly: false);
      expect(data.entries.any((entry) => entry.sessionKey == chat.key), isTrue);
      expect(
        data.entries
            .firstWhere((entry) => entry.sessionKey == chat.key)
            .project!
            .id,
        'p2',
      );
    },
  );
}

class _FailingDraftStore extends ComposerDraftStore {
  _FailingDraftStore(super.preferences)
    : super(connectionIdentity: 'mutations');
  bool failClear = false;
  String? heldText;
  Completer<void>? writeStarted;
  Completer<void>? writeDelay;
  int clearAttempts = 0;

  @override
  Future<void> write({
    required String profileName,
    required String sessionId,
    required String text,
    Iterable<ComposerReference> references = const [],
    required Iterable<AttachmentDraft> attachments,
    bool submissionUncertain = false,
    Iterable<QueuedPromptDraft> queuedPrompts = const [],
    bool queuePaused = false,
  }) async {
    if (text.isEmpty && attachments.isEmpty && queuedPrompts.isEmpty) {
      clearAttempts++;
      if (failClear) throw StateError('Local draft cleanup failed');
    }
    if (text == heldText && writeDelay != null) {
      final delay = writeDelay!;
      writeDelay = null;
      writeStarted!.complete();
      await delay.future;
    }
    await super.write(
      profileName: profileName,
      sessionId: sessionId,
      text: text,
      references: references,
      attachments: attachments,
      submissionUncertain: submissionUncertain,
      queuedPrompts: queuedPrompts,
      queuePaused: queuePaused,
    );
  }
}

class _FailingAttachmentService extends AttachmentDraftService {
  _FailingAttachmentService(Directory directory)
    : super(cacheDirectoryProvider: () async => directory);
  bool failRemove = false;
  final removeAttempts = <String>[];
  List<String> _validatedIds = const [];

  @override
  Future<ValidatedAttachmentCleanup> validateDeletedDraftCleanup(
    Iterable<AttachmentDraft> drafts,
  ) async {
    final captured = drafts.toList();
    final result = await super.validateDeletedDraftCleanup(captured);
    _validatedIds = captured.map((d) => d.id).toList();
    return result;
  }

  @override
  Future<void> removeDeletedDraftCleanup(
    ValidatedAttachmentCleanup batch,
  ) async {
    removeAttempts.addAll(_validatedIds);
    if (failRemove) throw StateError('Cached attachment cleanup failed');
    await super.removeDeletedDraftCleanup(batch);
  }
}

class _CleanupPreferences extends InMemorySharedPreferencesStore {
  _CleanupPreferences() : super.empty();
  String? failPhase;
  String? holdPhase;
  Completer<void>? writeStarted;
  Completer<void>? writeDelay;
  bool failRetirement = false;
  Completer<void>? holdRetirement;
  Completer<void>? retirementStarted;
  @override
  Future<bool> remove(String key) async {
    if (key.startsWith('flutter.deleted_draft_cleanup_v1.')) {
      if (holdRetirement != null) {
        final gate = holdRetirement!;
        holdRetirement = null;
        retirementStarted!.complete();
        await gate.future;
      }
      if (failRetirement) return false;
    }
    return super.remove(key);
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.startsWith('flutter.deleted_draft_cleanup_v1.') &&
        value is String &&
        (jsonDecode(value) as Map)['phase'] == holdPhase &&
        writeDelay != null) {
      final delay = writeDelay!;
      writeDelay = null;
      writeStarted!.complete();
      await delay.future;
    }
    if (key.startsWith('flutter.deleted_draft_cleanup_v1.') &&
        value is String &&
        (jsonDecode(value) as Map)['phase'] == failPhase) {
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}
