import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/answer_versions.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/models/deleted_draft_cleanup.dart';
import 'package:wing/core/models/detached_work.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';

import '../test/helpers/journey_controls.dart';
import '../test/support/existing_backend_login.dart';
import 'support/journey_capture.dart';

const _nonce = String.fromEnvironment('WING_QA_NONCE');

Future<void> waitForProductionState(
  WidgetTester tester,
  bool Function() ready,
  String phase, {
  int seconds = 180,
}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    final failure = tester.takeException();
    if (failure != null) throw failure;
  }
  expect(ready(), isTrue, reason: phase);
}

Future<ProfileWorkspaceController> productionWorkspace(
  String id, {
  String profile = 'default',
}) async {
  expect(RegExp(r'^[a-z0-9-]{8,60}$').hasMatch(_nonce), isTrue);
  expect(
    profile == 'default' || profile == _nonce,
    isTrue,
    reason: 'Use default or the exact runner-owned QA profile',
  );
  final connection = await readExistingBackendConnection(
    url: const String.fromEnvironment('WING_HERMES_URL'),
    loginFile: const String.fromEnvironment('WING_HERMES_LOGIN_FILE'),
    id: id,
  );
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final appPrefs = AppPreferences(prefs);
  final owner = ProfileWorkspaceController(
    appPreferences: appPrefs,
    access: ConnectionAccess(connection: connection, dashboardOAuth: null),
    connectionIdentity: id,
    preferences: prefs,
  );
  addTearDown(() {
    owner.dispose();
    appPrefs.dispose();
  });
  await owner.initialize();
  if (owner.current?.scope.profileName != profile) {
    expect(await owner.switchProfile(profile), isTrue);
  }
  expect(owner.error, isNull);
  return owner;
}

Future<void> showProductionWorkspace(
  WidgetTester tester,
  ProfileWorkspaceController owner,
) async {
  await tester.pumpWidget(
    journeyCaptureBoundary(
      MaterialApp(
        theme: wingTheme(Brightness.dark),
        home: ProfileWorkspaceScreen(key: ValueKey(owner), controller: owner),
      ),
    ),
  );
  await tester.pump();
}

Future<void> sendProductionText(WidgetTester tester, String text) async {
  final field = find.byKey(const Key('profile-message-composer'));
  await tapJourneyControl(tester, field);
  await tester.enterText(field, text);
  await tester.pump();
  await tapJourneyControl(tester, find.byTooltip('Send'));
  await tester.pump();
}

Future<void> _clean(
  WidgetTester tester,
  ProfileWorkspaceController owner,
  ProfileChat chat,
  String title,
  Map<String, dynamic> receipt,
  Future<void> Function() checkpoint,
) async {
  receipt['cleanup'] = 'settling owned work';
  await checkpoint();
  if (chat.runtime.blocksTurnAdmission) {
    await owner.stop(chat).timeout(const Duration(seconds: 30));
  }
  await waitForProductionState(
    tester,
    () => !chat.runtime.blocksTurnAdmission && !chat.runtime.commandRunning,
    'Owned turn and command settle before cleanup',
    seconds: 90,
  );
  final gateway = owner.current!.gateway;
  final profile = chat.key.workspace.profileName;
  final deadline = DateTime.now().add(const Duration(seconds: 240));
  var running = true;
  while (running && DateTime.now().isBefore(deadline)) {
    final roster = DetachedWork.parseRoster(
      await gateway
          .detachedWorkRoster(profile)
          .timeout(const Duration(seconds: 30)),
    );
    running = roster.any(
      (row) => row.sessionId == chat.key.sessionId && row.isRunning,
    );
    receipt['owned_work_running'] = running;
    await checkpoint();
    if (running) await tester.pump(const Duration(seconds: 1));
  }
  expect(
    running,
    isFalse,
    reason: 'Retain ownership while background work is unfinished',
  );
  final metadata = await gateway.sessionMetadata(chat.key.sessionId);
  if (metadata != null) {
    expect(
      metadata['id'],
      chat.key.sessionId,
      reason: 'Cleanup exact owned ID',
    );
    expect(metadata['profile'], profile);
    if (receipt['rename_confirmed'] == true) {
      expect(metadata['title'], title, reason: 'Cleanup exact QA title');
    }
    receipt['cleanup'] = 'delete requested; result unconfirmed';
    receipt['delete_requested_at'] = DateTime.now().toUtc().toIso8601String();
    await checkpoint();
    await owner.mutateSession(chat.key, delete: true, canDispatch: () => true);
  }
  for (final id in (receipt['session_ids'] as List).cast<String>()) {
    expect(
      await gateway.verifyDeletedSession(id),
      SessionPresence.absent,
      reason: 'Every recorded owned conversation identity is absent',
    );
  }
  receipt['cleanup'] = 'confirmed absent';
  await checkpoint();
  debugPrint('WING_PROD_CLEANUP confirmed owned conversation absent');
}

/// Persist ownership before rename or inference, and retain both the original
/// verdict and any cleanup failure. The host pulls these files even on failure.
Future<void> ownedProductionJourney(
  WidgetTester tester,
  ProfileWorkspaceController owner,
  String kind,
  String title,
  Future<void> Function(ProfileChat, Future<void> Function()) body,
) async {
  expect(
    owner.current?.chat,
    isNull,
    reason: 'New chat must create an owned conversation',
  );
  final profile = owner.current!.scope.profileName;
  expect(profile == 'default' || profile == _nonce, isTrue);
  final file = File(
    '${Directory.systemTemp.path}/wing-prod-owned-$_nonce-$kind.json',
  );
  expect(
    await file.exists(),
    isFalse,
    reason: 'Never replace a previous ownership receipt',
  );
  final receipt = <String, dynamic>{
    'nonce': _nonce,
    'origin': const String.fromEnvironment('WING_HERMES_URL'),
    'profile': profile,
    'title': title,
    'kind': kind,
    'creation': 'requested through New chat',
    'created_at': DateTime.now().toUtc().toIso8601String(),
    'rename_confirmed': false,
    'outcome': 'incomplete',
    'cleanup': 'not started',
  };
  ProfileChat? owned;
  Future<void> checkpoint() async {
    if (owned case final chat?) {
      receipt['created_session_id'] ??= chat.key.sessionId;
      receipt['session_id'] = chat.key.sessionId;
      receipt['runtime_id'] = chat.runtime.runtimeId;
      receipt['session_ids'] = {
        ...?receipt['session_ids'] as List?,
        chat.key.sessionId,
      }.toList();
    }
    final pending = File('${file.path}.pending');
    await pending.writeAsString(jsonEncode(receipt), flush: true);
    await pending.rename(file.path);
  }

  Future<void> captureFailure() async {
    try {
      await captureJourney(tester, 'prod-$kind-failure', failure: true);
    } catch (_) {
      // Capture failure must not replace the production or cleanup verdict.
    }
  }

  Object? primaryFailure, cleanupFailure;
  StackTrace? primaryStack, cleanupStack;
  await checkpoint();
  try {
    await tapJourneyControl(
      tester,
      find.byKey(const ValueKey('workspace-new-chat')),
    );
    await waitForProductionState(
      tester,
      () =>
          owner.current?.chat != null ||
          find.text('Choose profile').evaluate().isNotEmpty,
      'New chat resolves its profile selection',
    );
    if (owner.current?.chat == null) {
      final chooserRoute = ModalRoute.of(
        tester.element(find.text('Choose profile')),
      );
      expect(chooserRoute, isNotNull);
      expect(chooserRoute!.isCurrent, isTrue);
      // This popup lazily builds five visible rows. Scope real touch drags to
      // its route so discovering a later QA profile cannot scroll saved chats.
      final options = find.byElementPredicate(
        (element) =>
            element.widget is Scrollable &&
            ModalRoute.of(element) == chooserRoute,
      );
      expect(options, findsOneWidget);
      final choice = find.byKey(ValueKey('chat-menu-$profile'));
      await dragViewportToControl(tester, options, choice);
      await tapJourneyControl(tester, choice);
    }
    await waitForProductionState(
      tester,
      () => owner.current?.chat != null,
      'Owned QA chat opened',
    );
    final chat = owned = owner.current!.chat!;
    receipt['creation'] = 'confirmed';
    await checkpoint();
    receipt['rename_requested_at'] = DateTime.now().toUtc().toIso8601String();
    await checkpoint();
    await owner.mutateSession(
      chat.key,
      changes: {'title': title},
      canDispatch: () => true,
    );
    final metadata = await owner.current!.gateway.sessionMetadata(
      chat.key.sessionId,
    );
    expect(
      metadata?['title'],
      title,
      reason: 'Owned QA rename is confirmed before usage',
    );
    expect(metadata?['profile'], profile);
    receipt['rename_confirmed'] = true;
    await checkpoint();
    await body(chat, checkpoint);
    receipt['outcome'] = 'passed';
  } catch (error, stack) {
    primaryFailure = error;
    primaryStack = stack;
    // A Flutter failure can surface on the same frame that publishes creation.
    // Capture that new identity before cleanup even if the wait threw first.
    owned ??= owner.current?.chat;
    receipt['outcome'] = 'failed';
    receipt['primary_error_type'] = error.runtimeType.toString();
    await captureFailure();
  } finally {
    try {
      if (owned case final chat?) {
        await _clean(tester, owner, chat, title, receipt, checkpoint);
      } else {
        receipt['cleanup'] =
            'creation unresolved; inspect before further action';
      }
    } catch (error, stack) {
      cleanupFailure = error;
      cleanupStack = stack;
      receipt['cleanup_error_type'] = error.runtimeType.toString();
      receipt['cleanup'] = 'unconfirmed; retained for operator recovery';
      await captureFailure();
    } finally {
      try {
        await checkpoint();
      } catch (error, stack) {
        cleanupFailure ??= error;
        cleanupStack ??= stack;
        debugPrint(
          'WING_PROD_RECEIPT final checkpoint failed; retain prior ownership file',
        );
      }
      try {
        await tester.pumpWidget(const SizedBox.shrink());
      } catch (error, stack) {
        cleanupFailure ??= error;
        cleanupStack ??= stack;
      }
    }
  }
  if (cleanupFailure != null) {
    debugPrint(
      'WING_PROD_CLEANUP unconfirmed; inspect wing-prod-owned receipt',
    );
  }
  if (primaryFailure != null) {
    Error.throwWithStackTrace(primaryFailure, primaryStack!);
  }
  if (cleanupFailure != null) {
    Error.throwWithStackTrace(cleanupFailure, cleanupStack!);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  testJourney('production Android compression preview and applied history', (
    tester,
  ) async {
    final owner = await productionWorkspace('wing-prod-compression-$_nonce');
    await showProductionWorkspace(tester, owner);
    final gateway = owner.current!.gateway;
    final title = 'Wing production compression QA $_nonce';
    await ownedProductionJourney(tester, owner, 'compression', title, (
      chat,
      checkpoint,
    ) async {
      // Stock protects its first 3 and last 20 messages. Fourteen actual turns
      // leave a real middle to summarize without changing shared configuration.
      for (var turn = 1; turn <= 14; turn++) {
        final marker = 'WING_QA_${_nonce}_$turn';
        await sendProductionText(
          tester,
          'Isolated Wing acceptance $_nonce turn $turn. Reply exactly $marker. '
          'Do not call tools, delegate, browse, or read/change files.',
        );
        await waitForProductionState(
          tester,
          () =>
              !chat.runtime.blocksTurnAdmission &&
              chat.reading.messages.any(
                (row) =>
                    row['role'] == 'assistant' &&
                    answerMessageText(row).contains(marker),
              ),
          'Real reply $turn persisted in the UI',
        );
        expect(chat.runtime.error, isNull);
        expect(chat.runtime.execution, ChatExecution.completed);
        await checkpoint();
        debugPrint('WING_PROD_TURN $turn completed');
      }
      final before = await gateway.history(chat.key.sessionId);
      expect(before.rows.length, greaterThanOrEqualTo(28));
      await captureJourney(tester, 'prod-compression-before');
      await sendProductionText(tester, '/compress --preview');
      await waitForProductionState(
        tester,
        () =>
            !chat.runtime.commandRunning &&
            chat.composer.observation.text.isEmpty,
        'Preview acknowledged',
      );
      expect(chat.runtime.error, isNull);
      expect(
        jsonEncode((await gateway.history(chat.key.sessionId)).rows),
        jsonEncode(before.rows),
      );
      const previewText = 'Preview — no changes made.';
      expect(
        chat.reading.messages.any(
          (row) =>
              row['_command_notice'] == true &&
              answerMessageText(row).contains(previewText),
        ),
        isTrue,
      );
      await dragTranscriptToControl(
        tester,
        find.textContaining(previewText, findRichText: true),
      );
      await captureJourney(tester, 'prod-compression-preview');
      final revision = gateway.canonical
          .session(chat.runtime.runtimeId)!
          .revision;
      await sendProductionText(tester, '/compress');
      await waitForProductionState(
        tester,
        () =>
            !chat.runtime.commandRunning &&
            chat.composer.observation.text.isEmpty,
        'Compression acknowledged',
        seconds: 600,
      );
      expect(chat.runtime.error, isNull);
      await checkpoint();
      final after = await gateway.history(chat.key.sessionId);
      final next = gateway.canonical.session(chat.runtime.runtimeId)!;
      expect(
        next.revision,
        greaterThan(revision),
        reason: 'Actual compression committed, not a no-op',
      );
      expect(jsonEncode(after.rows), isNot(jsonEncode(before.rows)));
      expect(after.rows, isNotEmpty);
      expect(
        chat.reading.messages.any(
          (row) => answerMessageText(row).contains(
            'Compression finished. Refresh to reload history and context.',
          ),
        ),
        isFalse,
      );
      List<String> visibleRows(Iterable<Map<String, dynamic>> rows) => rows
          .where((row) => row['_command_notice'] != true)
          .map((row) => jsonEncode([row['role'], answerMessageText(row)]))
          .toList();
      expect(
        visibleRows(chat.reading.messages),
        visibleRows(after.rows),
        reason: 'The compressed saved history must reach Wing reading state',
      );
      final appliedNotice = chat.reading.messages.lastWhere(
        (row) =>
            row['_command_notice'] == true && row['_command'] == '/compress',
      );
      final headline = answerMessageText(appliedNotice).split('\n').first;
      expect(headline, isNot(previewText));
      await dragTranscriptToControl(
        tester,
        find.textContaining(headline, findRichText: true),
      );
      await captureJourney(tester, 'prod-compression-applied');
      debugPrint(
        'WING_PROD_COMPRESSION ${jsonEncode({'before': before.rows.length, 'after': after.rows.length, 'revision_before': revision, 'revision_after': next.revision, 'preview_unchanged': true})}',
      );
      await tapJourneyControl(
        tester,
        find.byKey(const Key('profile-message-composer')),
      );
      await tester.enterText(
        find.byKey(const Key('profile-message-composer')),
        'Unsent draft after real compression',
      );
      await tester.pump();
      expect(
        chat.composer.observation.text,
        'Unsent draft after real compression',
      );
      await captureJourney(tester, 'prod-compression-new-draft');
    });
  });

  testJourney('production Android discovers detached work without attachment', (
    tester,
  ) async {
    final actor = await productionWorkspace('wing-prod-actor-$_nonce');
    await showProductionWorkspace(tester, actor);
    final title = 'Wing detached production QA $_nonce';
    await ownedProductionJourney(tester, actor, 'detached', title, (
      chat,
      checkpoint,
    ) async {
      final observer = await productionWorkspace('wing-prod-observer-$_nonce');
      final gateway = observer.current!.gateway;
      await sendProductionText(
        tester,
        'Isolated Wing detached-work acceptance $_nonce. Use terminal once with background=true '
        'to compute a finite CPU-only SHA256 chain in Python: initialize x to the bytes wing-qa, '
        'then repeat x = hashlib.sha256(x).digest() exactly 60000000 times and print x.hex(). '
        'Use python3 -c and an ordinary for loop with constant memory; do not retain intermediate results. '
        'Do not read/write files, access the network, sleep, or launch any other jobs. '
        'Report the background process id immediately; do not wait for completion.',
      );
      final deadline = DateTime.now().add(const Duration(seconds: 180));
      var observed = false;
      while (!observed && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 250));
        final roster = DetachedWork.parseRoster(
          await gateway.detachedWorkRoster('default'),
        );
        observed =
            !chat.runtime.blocksTurnAdmission &&
            chat.runtime.execution == ChatExecution.completed &&
            roster.any(
              (row) =>
                  row.sessionId == chat.key.sessionId && row.background > 0,
            );
        if (chat.runtime.error != null) {
          fail('QA work failed before detached observation');
        }
      }
      expect(
        observed,
        isTrue,
        reason:
            'Require a completed actor turn with a still-running owned background process',
      );
      await checkpoint();
      expect(
        gateway.canonical.session(chat.runtime.runtimeId),
        isNull,
        reason: 'Observer has no authority for the QA actor',
      );
      await showProductionWorkspace(tester, observer);
      await tapJourneyControl(tester, find.byTooltip('Open navigation menu'));
      await tapJourneyControl(tester, find.text('Recents'));
      // Canonical active_list can also report this conversation while the agent
      // is replying. Only a null runtime ID proves this card came from N20.
      final detachedDeadline = DateTime.now().add(const Duration(seconds: 90));
      var detached = false;
      while (!detached && DateTime.now().isBefore(detachedDeadline)) {
        await observer.refreshActivity();
        detached = observer.liveActivity.any(
          (row) => row.sessionId == chat.key.sessionId && row.runtimeId == null,
        );
        if (!detached) await tester.pump(const Duration(milliseconds: 250));
      }
      expect(
        detached,
        isTrue,
        reason: 'Recents must contain the detached-only activity row',
      );
      final card = find.byKey(
        ValueKey('activity-default-${chat.key.sessionId}'),
      );
      await revealJourneyControl(tester, card);
      expect(card.hitTestable(), findsOneWidget);
      expect(gateway.canonical.session(chat.runtime.runtimeId), isNull);
      expect(chat.runtime.blocksTurnAdmission, isFalse);
      expect(
        DetachedWork.parseRoster(
          await gateway.detachedWorkRoster('default'),
        ).any(
          (row) => row.sessionId == chat.key.sessionId && row.background > 0,
        ),
        isTrue,
        reason:
            'Owned process must still be running for the detached UI capture',
      );
      expect(
        observer.liveActivity
            .singleWhere((row) => row.sessionId == chat.key.sessionId)
            .runtimeId,
        isNull,
      );
      await captureJourney(tester, 'prod-detached-recents');
      debugPrint(
        'WING_PROD_DETACHED settled actor, nonempty roster, detached Recents, no observer attachment',
      );
      await waitForProductionState(
        tester,
        () => !chat.runtime.blocksTurnAdmission,
        'Actor finishes',
        seconds: 240,
      );
      final end = DateTime.now().add(const Duration(seconds: 240));
      var running = true;
      while (running && DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(seconds: 1));
        running = DetachedWork.parseRoster(
          await gateway.detachedWorkRoster('default'),
        ).any((row) => row.sessionId == chat.key.sessionId && row.isRunning);
      }
      expect(
        running,
        isFalse,
        reason: 'Finite owned background process completed',
      );
      await observer.refreshActivity();
      expect(
        observer.liveActivity.where(
          (row) => row.sessionId == chat.key.sessionId,
        ),
        isEmpty,
      );
      await captureJourney(tester, 'prod-detached-settled');
    });
  });
}
