import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/bots.dart';
import 'package:wing/core/models/scheduled_task.dart';
import 'package:wing/core/screens/administration/admin_scheduled_tasks_page.dart';
import 'package:wing/core/screens/administration/admin_scheduled_task_editor_page.dart';
import 'package:wing/core/screens/administration/admin_scheduled_task_detail_page.dart';
import 'package:wing/core/screens/bots/bot_group_context_sheet.dart';
import 'package:wing/core/screens/bots/bot_group_screen.dart';
import 'package:wing/core/services/bot_group_session.dart';
import 'package:wing/core/services/bots_repository.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/scheduled_tasks_controller.dart';
import 'package:wing/core/services/scheduled_tasks_repository.dart';
import 'package:wing/core/theme/wing_theme.dart';

import '../test/helpers/journey_controls.dart';
import 'hermes_next_conversation_prod_test.dart'
    show productionWorkspace, waitForProductionState;
import 'support/journey_capture.dart';

const _nonce = String.fromEnvironment('WING_QA_NONCE');
const _profileA = String.fromEnvironment('WING_QA_PROFILE');
const _profileB = String.fromEnvironment('WING_QA_PROFILE_B');

/// Both members are fresh runner-owned profiles. Only the exact room and
/// jobs recorded here may be changed. The runner deletes the profiles after
/// these manifests confirm that their group/task work has stopped and vanished.
class _OwnedObjects {
  _OwnedObjects(this.workspace, this.kind)
    : roomId = '$_nonce-$kind',
      roomName = 'Wing QA $_nonce $kind',
      file = File(
        '${Directory.systemTemp.path}/wing-prod-owned-$_nonce-$kind.json',
      ),
      bots = BotsRepository.forServer(
        workspace.administration(),
        groupObservations: workspace.groupObservations,
      ),
      tasks = ScheduledTasksRepository(
        workspace.administration().profile(_profileA),
      );

  final ProfileWorkspaceController workspace;
  final String kind, roomId, roomName;
  final File file;
  final BotsRepository bots;
  final ScheduledTasksRepository tasks;
  final receipt = <String, dynamic>{};
  final taskNames = <String>{};
  final taskIds = <String, String>{};
  BotGroup? room;
  bool creationRequested = false;

  Future<void> checkpoint() async {
    receipt['task_names'] = taskNames.toList();
    receipt['task_ids'] = taskIds;
    final pending = File('${file.path}.pending');
    await pending.writeAsString(jsonEncode(receipt), flush: true);
    await pending.rename(file.path);
  }

  Future<void> prepare() async {
    expect(RegExp(r'^[a-z0-9-]{8,60}$').hasMatch(_nonce), isTrue);
    expect(_profileA, '$_nonce-a');
    expect(_profileB, '$_nonce-b');
    expect(await file.exists(), isFalse);
    expect((await bots.groupCatalog()).any((row) => row.id == roomId), isFalse);
    expect(await tasks.list(), isEmpty, reason: 'Fresh QA profile has no jobs');
    final members = (await bots.bots())
        .where((bot) => [_profileA, _profileB].contains(bot.profile.name))
        .toList();
    expect(members.length, 2, reason: 'Requires both exact owned profiles');
    receipt.addAll({
      'nonce': _nonce,
      'origin': const String.fromEnvironment('WING_HERMES_URL'),
      'kind': kind,
      'profiles': [_profileA, _profileB],
      'room_id': roomId,
      'room_name': roomName,
      'host_profile': 'default',
      'outcome': 'incomplete',
      'cleanup': 'not started',
      'creation': 'group requested',
    });
    await checkpoint();
    creationRequested = true;
    await bots.createGroup(roomId, roomName, members, () => true, () {});
    room = (await bots.groupCatalog()).singleWhere((row) => row.id == roomId);
    _verifyRoom(room!);
    receipt['creation'] = 'group confirmed';
    await checkpoint();
  }

  void _verifyRoom(BotGroup value) {
    expect(value.id, roomId);
    expect(value.name, roomName);
    expect(value.scope.profileName, 'default');
    expect(
      value.members.map((member) => member.profile),
      unorderedEquals([_profileA, _profileB]),
    );
  }

  Future<ScheduledTask> createTask(String suffix, String prompt) async {
    final name = 'Wing QA $_nonce $suffix';
    expect((await tasks.list()).any((task) => task.name == name), isFalse);
    taskNames.add(name);
    receipt['creation'] = 'task requested';
    await checkpoint();
    final task = await tasks.create({
      'name': name,
      'prompt': prompt,
      'schedule': '0 0 1 1 *',
      'timezone': 'UTC',
      'catch_up': false,
      'deliver': 'local',
      'enabled_toolsets': <String>[],
    });
    expect(task.profileName, _profileA);
    expect(task.name, name);
    taskIds[task.id] = name;
    receipt['creation'] = 'task confirmed';
    await checkpoint();
    return task;
  }

  Future<ScheduledTask> readOwnedExecution(String id) async {
    final expectedName = taskIds[id];
    expect(
      expectedName,
      isNotNull,
      reason: 'Execution read requires recorded ownership',
    );
    // Stock GET /cron/jobs/:id has stored policy only. The scoped list adds
    // live/latest execution metadata, including work behind a pending trigger.
    final task = (await tasks.list()).singleWhere((row) => row.id == id);
    expect(task.profileName, _profileA);
    expect(task.name, expectedName);
    return task;
  }

  Future<void> cleanup(WidgetTester tester) async {
    if (!creationRequested) return;
    receipt['cleanup'] = 'checking exact owned objects';
    await checkpoint();
    // Recover a server-generated ID after a lost create response only by the
    // unique name recorded before dispatch in a profile proven empty at setup.
    for (final task in await tasks.list()) {
      if (taskNames.contains(task.name)) taskIds[task.id] = task.name;
    }
    await checkpoint();
    for (final entry in taskIds.entries) {
      var task = await readOwnedExecution(entry.key);
      expect(task.profileName, _profileA);
      expect(task.name, entry.value);
      if (task.running) await tasks.cancel(task.id);
      final deadline = DateTime.now().add(const Duration(seconds: 120));
      while (task.running && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(seconds: 1));
        task = await readOwnedExecution(entry.key);
      }
      expect(
        task.running,
        isFalse,
        reason: 'Owned task must stop before delete',
      );
      expect(task.profileName, _profileA);
      expect(task.name, entry.value);
      await tasks.delete(task.id);
      expect((await tasks.list()).any((row) => row.id == task.id), isFalse);
    }
    final found = (await bots.groupCatalog())
        .where((row) => row.id == roomId)
        .firstOrNull;
    if (found != null) {
      _verifyRoom(found);
      var runtime = (await bots.groupRuntime(found)).runtime;
      if (runtime.working || runtime.blocked) {
        await bots.groupAction(
          found,
          'stop',
          '$_nonce-$kind-cleanup-stop',
          () => true,
          () {},
        );
      }
      final deadline = DateTime.now().add(const Duration(seconds: 120));
      while ((runtime.working || runtime.blocked) &&
          DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(seconds: 1));
        runtime = (await bots.groupRuntime(found)).runtime;
      }
      expect(runtime.working || runtime.blocked, isFalse);
      _verifyRoom(
        (await bots.groupCatalog()).singleWhere((row) => row.id == roomId),
      );
      await bots.groupAction(
        found,
        'disband',
        '$_nonce-$kind-cleanup-disband',
        () => true,
        () {},
      );
    }
    expect((await bots.groupCatalog()).any((row) => row.id == roomId), isFalse);
    expect(
      (await tasks.list()).any((task) => taskNames.contains(task.name)),
      isFalse,
    );
    receipt['cleanup'] = 'confirmed absent';
    await checkpoint();
  }
}

Future<void> _journey(
  WidgetTester tester,
  String kind,
  Future<void> Function(_OwnedObjects) body,
) async {
  final workspace = await productionWorkspace('wing-prod-$_nonce-$kind');
  final owned = _OwnedObjects(workspace, kind);
  Object? failure, cleanupFailure;
  StackTrace? failureStack, cleanupStack;
  try {
    await owned.prepare();
    await body(owned);
    owned.receipt['outcome'] = 'passed';
    await owned.checkpoint();
  } catch (error, stack) {
    failure = error;
    failureStack = stack;
    if (owned.creationRequested) {
      owned.receipt['outcome'] = 'failed';
      try {
        await owned.checkpoint();
      } catch (_) {
        debugPrint(
          'WING_PROD_MANIFEST_WRITE_FAILED $kind; original failure retained',
        );
      }
    }
    try {
      await captureJourney(tester, 'prod-$kind-failure', failure: true);
    } catch (_) {
      // Preserve the original production verdict when capture also fails.
    }
  } finally {
    try {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    } catch (error, stack) {
      failure ??= error;
      failureStack ??= stack;
    }
    // A broken render must not suppress exact backend cleanup.
    try {
      await owned.cleanup(tester);
    } catch (error, stack) {
      cleanupFailure = error;
      cleanupStack = stack;
      if (owned.creationRequested) {
        owned.receipt['cleanup'] = 'failed; ownership retained';
        try {
          await owned.checkpoint();
        } catch (_) {
          debugPrint(
            'WING_PROD_MANIFEST_WRITE_FAILED $kind; cleanup failure retained',
          );
        }
      }
    }
  }
  if (failure != null) {
    if (cleanupFailure != null) {
      debugPrint('WING_PROD_CLEANUP_FAILED $kind; inspect retained manifest');
    }
    Error.throwWithStackTrace(failure, failureStack!);
  }
  if (cleanupFailure != null) {
    Error.throwWithStackTrace(cleanupFailure, cleanupStack!);
  }
}

Future<void> _visible(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; finder.evaluate().isEmpty && attempt < 16; attempt++) {
    final scrollable = find
        .byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        )
        .hitTestable();
    expect(
      scrollable,
      findsWidgets,
      reason: 'Visible route must be scrollable',
    );
    await tester.drag(scrollable.last, const Offset(0, -330));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await revealJourneyControl(tester, finder);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _visible(tester, finder);
  await tapJourneyControl(tester, finder);
  await tester.pump();
}

Future<void> _enter(WidgetTester tester, Finder field, String value) async {
  await _tap(tester, field);
  await tester.enterText(field, value);
  await tester.pump();
}

Future<void> _select(WidgetTester tester, String label, String option) async {
  final dropdown = find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((widget) => widget is DropdownMenu),
  );
  await _tap(tester, dropdown);
  // Moving from an editable field to this select-only field dismisses the
  // native keyboard. Its viewport change can close the just-opened menu.
  await waitForProductionState(
    tester,
    () => tester.view.viewInsets.bottom == 0,
    '$label keyboard dismissal completes',
    seconds: 15,
  );
  await tester.pump();
  final closedArrow = find.descendant(
    of: dropdown,
    matching: find.byIcon(Icons.arrow_drop_down),
  );
  if (closedArrow.hitTestable().evaluate().isNotEmpty) {
    await _tap(tester, closedArrow);
  }
  // A non-positional finder remains safe while the popup animates or relayouts.
  // Do not scroll the underlying editor while waiting for a menu item.
  await tapJourneyControl(
    tester,
    find.widgetWithText(MenuItemButton, option).hitTestable(),
  );
  await tester.pump();
}

Future<BotGroupSession> _showGroup(
  WidgetTester tester,
  _OwnedObjects owned,
) async {
  final roster = BotsSession((_) async => [owned.bots]);
  addTearDown(roster.dispose);
  await roster.refresh();
  late BotGroupSession session;
  await tester.pumpWidget(
    journeyCaptureBoundary(
      MaterialApp(
        key: UniqueKey(),
        theme: wingTheme(Brightness.dark),
        home: BotGroupScreen(
          createSession: () => session = roster.openGroup(owned.room!),
          voiceInputSettings: () => null,
          stopVoicePlayback: () async {},
        ),
      ),
    ),
  );
  await waitForProductionState(
    tester,
    () => session.runtime != null && session.context != null,
    'Owned group runtime and context open',
  );
  expect(session.error, isNull);
  return session;
}

Future<void> _openContext(WidgetTester tester) async {
  await _tap(tester, find.byTooltip('Group options'));
  await _tap(tester, find.text('Shared settings'));
  await waitForProductionState(
    tester,
    () => find.byType(BotGroupContextSheet).evaluate().isNotEmpty,
    'Shared settings opens',
  );
}

Future<ScheduledTasksController> _showTasks(
  WidgetTester tester,
  _OwnedObjects owned,
) async {
  final preferences = await SharedPreferences.getInstance();
  late ScheduledTasksController controller;
  await tester.pumpWidget(
    journeyCaptureBoundary(
      MaterialApp(
        key: UniqueKey(),
        theme: wingTheme(Brightness.dark),
        home: AdminScheduledTasksPage(
          profile: owned.tasks.profile,
          acquireController: () =>
              controller = ScheduledTasksController.acquire(
                owned.tasks.profile,
                preferences,
              ),
          onOpenSession: (_) async {},
        ),
      ),
    ),
  );
  await waitForProductionState(
    tester,
    () => controller.tasks != null && !controller.loading,
    'Owned profile tasks load',
  );
  expect(controller.error, isNull);
  return controller;
}

Future<void> _editTask(WidgetTester tester, ScheduledTask task) async {
  await _tap(tester, find.byTooltip('Actions for ${task.name}'));
  await _tap(tester, find.text('Edit task'));
  await waitForProductionState(
    tester,
    () => find.byType(AdminScheduledTaskEditorPage).evaluate().isNotEmpty,
    'Owned task editor opens',
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets('Production N09 N10 group settings persist and N03 work stops', (
    tester,
  ) async {
    await _journey(tester, 'groups', (owned) async {
      var session = await _showGroup(tester, owned);
      expect(
        session.runtime!.routingModes,
        containsAll(['everyone', 'auto', 'lead']),
      );
      for (final mode in ['auto', 'lead', 'everyone']) {
        await _openContext(tester);
        await _enter(
          tester,
          find.widgetWithText(TextField, 'Purpose'),
          'Verify owned Wing group $_nonce $mode',
        );
        await _enter(
          tester,
          find.widgetWithText(TextField, 'Shared notes'),
          'QA only. No files, network, delegation or external messages.',
        );
        await _select(tester, 'Routing', switch (mode) {
          'auto' => 'Auto',
          'lead' => 'Lead',
          _ => 'Everyone',
        });
        final lead = session.group.members.first;
        if (mode == 'lead') await _select(tester, 'Lead bot', lead.name);
        await _tap(tester, find.byTooltip('Save shared settings'));
        await captureJourney(tester, 'prod-group-$mode-save');
        await waitForProductionState(
          tester,
          () => find.byType(BotGroupContextSheet).evaluate().isEmpty,
          'Shared settings save closes after confirmation',
        );
        expect(session.error, isNull);
        final saved = (await owned.bots.groupRuntime(
          owned.room!,
        )).runtime.context!;
        expect(saved.purpose, 'Verify owned Wing group $_nonce $mode');
        expect(
          saved.notes,
          'QA only. No files, network, delegation or external messages.',
        );
        expect(saved.routing, mode);
        expect(saved.leadMemberId, mode == 'lead' ? lead.id : '');
        // A new route and session must read the backend's saved values.
        session = await _showGroup(tester, owned);
        await _openContext(tester);
        expect(find.text(saved.purpose), findsOneWidget);
        expect(find.text(saved.notes), findsOneWidget);
        expect(session.context!.routing, mode);
        await captureJourney(tester, 'prod-group-$mode-reopened');
        await _tap(tester, find.byTooltip('Cancel'));
      }
      final member = session.group.members.firstWhere(
        (row) => row.profile == _profileA,
      );
      await _enter(
        tester,
        find.byKey(const ValueKey('group-message-composer')),
        '@${member.handle} This is isolated QA. Without any tools, files, '
        'network requests or delegation, print integers 1 through 5000, '
        'one per line. Do not address or involve other group members.',
      );
      await _tap(tester, find.byTooltip('Send group message'));
      await waitForProductionState(
        tester,
        () =>
            session.runtime!.working &&
            session.runtime!.memberActivity.isNotEmpty,
        'Actual owned member work and reported progress appear',
      );
      await captureJourney(tester, 'prod-group-member-working');
      await _tap(tester, find.byTooltip('Group options'));
      await _tap(tester, find.text('Member activity'));
      await revealJourneyControl(
        tester,
        find.byTooltip('Close member activity'),
      );
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text('Member activity'),
        ),
        findsOneWidget,
      );
      await captureJourney(tester, 'prod-group-member-progress');
      await _tap(tester, find.byTooltip('Close member activity'));
      owned.receipt['member_progress_observed'] = true;
      await owned.checkpoint();
      await _tap(tester, find.byTooltip('Group options'));
      await _tap(tester, find.text('Stop group work'));
      await captureJourney(tester, 'prod-group-stop-requested');
      await waitForProductionState(
        tester,
        () =>
            !session.acting &&
            !session.awaitingStopFence &&
            session.runtime!.working == false &&
            session.runtime!.blocked == false,
        'Exact Stop fence observed and owned group settled',
      );
      expect(session.error, isNull);
      final log = await owned.bots.groupLog(owned.room!);
      expect(log.events.any((event) => event.cancelId.isNotEmpty), isTrue);
      await captureJourney(tester, 'prod-group-stop-confirmed');
      owned.receipt['stop_fence_confirmed'] = true;
      owned.receipt['continue'] =
          'not exercised: no naturally bounded discussion';
    });
  });

  testWidgets('Production N08 N12 task policy and group delivery persist', (
    tester,
  ) async {
    await _journey(tester, 'tasks', (owned) async {
      final marker = 'WING_DELIVERY_$_nonce';
      final task = await owned.createTask(
        'delivery',
        'Reply with exactly $marker and nothing else. Do not use tools, '
            'read files, delegate, mention anyone or send any messages.',
      );
      final controller = await _showTasks(tester, owned);
      await _editTask(tester, task);
      await _enter(
        tester,
        find.widgetWithText(TextFormField, 'Schedule timezone'),
        'Asia/Singapore',
      );
      await _select(tester, 'Missed runs', 'Run one catch-up');
      await _enter(
        tester,
        find.widgetWithText(TextFormField, 'Late window (min)'),
        '15',
      );
      await _tap(tester, find.text(owned.roomName));
      await _tap(tester, find.byTooltip('Save changes'));
      await captureJourney(tester, 'prod-task-policy-save');
      await waitForProductionState(
        tester,
        () => find.byType(AdminScheduledTaskEditorPage).evaluate().isEmpty,
        'Task policy save confirmed',
      );
      final saved = await owned.tasks.get(task.id);
      expect(saved.text('timezone'), 'Asia/Singapore');
      expect(saved.data['catch_up'], isTrue);
      expect(saved.data['grace_minutes'], 15);
      expect(saved.destinations, contains('room:${owned.roomId}@default'));
      await _editTask(tester, saved);
      await _visible(
        tester,
        find.widgetWithText(TextFormField, 'Schedule timezone'),
      );
      expect(
        tester
            .widget<TextFormField>(
              find.widgetWithText(TextFormField, 'Schedule timezone'),
            )
            .controller!
            .text,
        'Asia/Singapore',
      );
      await _visible(tester, find.text('Run one catch-up'));
      await captureJourney(tester, 'prod-task-policy-reopened');
      await _tap(tester, find.byTooltip('Cancel'));
      await _tap(tester, find.text(task.name));
      await waitForProductionState(
        tester,
        () => find.byType(AdminScheduledTaskDetailPage).evaluate().isNotEmpty,
        'Owned task detail opens',
      );
      await _tap(tester, find.byTooltip('Run now'));
      await captureJourney(tester, 'prod-task-delivery-dispatched');
      await waitForProductionState(
        tester,
        () => controller.task(task.id)?.latestExecution?.status == 'completed',
        'Real provider task execution completes',
        seconds: 240,
      );
      final confirmed = await owned.readOwnedExecution(task.id);
      expect(confirmed.latestExecution?.status, 'completed');
      expect(confirmed.running, isFalse);
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      var delivered = false;
      while (!delivered && DateTime.now().isBefore(deadline)) {
        final log = await owned.bots.groupLog(owned.room!);
        delivered = log.events.any((event) => event.text.contains(marker));
        if (!delivered) await tester.pump(const Duration(seconds: 1));
      }
      expect(
        delivered,
        isTrue,
        reason: 'Actual scheduled result reached owned group',
      );
      final group = await _showGroup(tester, owned);
      await waitForProductionState(
        tester,
        () => find.textContaining(marker).evaluate().isNotEmpty,
        'Delivered result appears in actual group transcript',
      );
      expect(
        group.runtime!.working,
        isFalse,
        reason: 'Unmentioned scheduled delivery must not wake members',
      );
      await captureJourney(tester, 'prod-task-result-in-group');
      owned.receipt['delivery_marker_confirmed'] = true;
      owned.receipt['execution_id'] = confirmed.latestExecution!.id;
    });
  });

  testWidgets('Production N11 continues an owned bounded group discussion', (
    tester,
  ) async {
    await _journey(tester, 'continue', (owned) async {
      final session = await _showGroup(tester, owned);
      final runtime = session.runtime!;
      expect(
        runtime.supports('continue'),
        isTrue,
        reason: 'Gateway must advertise the stock Continue operation',
      );
      expect(
        runtime.supports('stop'),
        isTrue,
        reason: 'Owned continuation must remain stoppable',
      );
      expect(
        runtime.maxRounds,
        isNotNull,
        reason: 'Gateway must report its real discussion round budget',
      );
      expect(
        runtime.maxRounds,
        inInclusiveRange(1, 3),
        reason:
            'QA permits at most three rounds; shared limits are never changed',
      );
      expect(
        runtime.maxContinues,
        greaterThanOrEqualTo(1),
        reason: 'Gateway must advertise at least one continuation grant',
      );
      expect(session.context!.routing, 'everyone');
      expect(session.group.members, hasLength(2));
      final memberA = session.group.members.singleWhere(
        (member) => member.profile == _profileA,
      );
      final memberB = session.group.members.singleWhere(
        (member) => member.profile == _profileB,
      );
      // max_messages is not exposed by stock driver_status. Two members and
      // at most three reported rounds independently cap this first grant at six
      // member turns; a smaller message limit can only stop it sooner.
      owned.receipt['max_rounds'] = runtime.maxRounds;
      owned.receipt['max_continues'] = runtime.maxContinues;
      owned.receipt['initial_member_turn_bound'] = 2 * runtime.maxRounds!;
      owned.receipt['continue_phase'] = 'bounded discussion requested';
      await owned.checkpoint();
      await _enter(
        tester,
        find.byKey(const ValueKey('group-message-composer')),
        'This is a finite, text-only QA ping-pong. No tools, files, network '
        'requests, external messages or delegation. '
        '@${memberA.handle}: on each of your first six turns in this discussion, '
        'reply with exactly "@${memberB.handle} ping". '
        '@${memberB.handle}: on each of your first six turns in this discussion, '
        'reply with exactly "@${memberA.handle} pong". '
        'Each reply is one short line. After your sixth reply do not request '
        'further responses. The gateway may pause this exchange sooner; '
        'respect its pause and resume only if the operator grants Continue.',
      );
      await _tap(tester, find.byTooltip('Send group message'));
      await waitForProductionState(
        tester,
        () =>
            session.continuations.length == 1 &&
            !session.runtime!.working &&
            !session.sending,
        'The real two-member exchange reaches an eligible bounded discussion',
        seconds: 240,
      );
      expect(session.error, isNull);
      final continuation = session.continuations.single;
      expect(continuation.grant, 1);
      final firstDiscussion = session.events.singleWhere(
        (event) => event.kind == 'message.user',
      );
      expect(continuation.discussionEventId, firstDiscussion.eventId);
      final replies = session.events
          .where(
            (event) =>
                event.kind == 'message.member' &&
                event.discussionEventId == continuation.discussionEventId,
          )
          .toList();
      expect(
        replies.length,
        inInclusiveRange(1, owned.receipt['initial_member_turn_bound'] as int),
      );
      expect(
        replies.every(
          (event) => {memberA.id, memberB.id}.contains(event.actorId),
        ),
        isTrue,
      );
      expect(
        session.events.any(
          (event) =>
              event.kind == 'room.activity' &&
              event.activityStatus == 'bounded' &&
              event.discussionEventId == continuation.discussionEventId,
        ),
        isTrue,
      );
      await _visible(tester, find.byTooltip('Continue discussion'));
      await captureJourney(tester, 'prod-group-continue-eligible');
      owned.receipt['discussion_event_id'] = continuation.discussionEventId;
      owned.receipt['initial_member_replies'] = replies.length;
      owned.receipt['continue_phase'] = 'one grant requested through UI';
      await owned.checkpoint();
      await _tap(tester, find.byTooltip('Continue discussion'));
      await captureJourney(tester, 'prod-group-continue-requested');
      await waitForProductionState(
        tester,
        () =>
            !session.acting &&
            session.events.any(
              (event) =>
                  event.kind == 'room.continued' &&
                  event.discussionEventId == continuation.discussionEventId &&
                  event.continueGrant == 1,
            ),
        'Continue produces the exact durable discussion grant',
      );
      expect(session.error, isNull);
      final continued = (await owned.bots.groupLog(
        owned.room!,
      )).events.where((event) => event.kind == 'room.continued').toList();
      expect(continued, hasLength(1));
      expect(
        continued.single.discussionEventId,
        continuation.discussionEventId,
      );
      expect(continued.single.continueGrant, 1);
      owned.receipt['continue_phase'] = 'exact grant confirmed';
      await owned.checkpoint();
      await waitForProductionState(
        tester,
        () => session.canStopGroupWork && session.runtime!.working,
        'Resumed owned group work offers Stop',
        seconds: 30,
      );
      owned.receipt['resumed_work_observed'] = true;
      // Stop as soon as the grant is proven; no second extension is admitted.
      await _tap(tester, find.byTooltip('Stop group work'));
      await waitForProductionState(
        tester,
        () =>
            !session.acting &&
            !session.awaitingStopFence &&
            !session.runtime!.working &&
            !session.runtime!.blocked,
        'Continued work stops and its exact fence is observed',
      );
      expect(session.error, isNull);
      final finalLog = (await owned.bots.groupLog(owned.room!)).events;
      expect(
        finalLog.any(
          (event) =>
              event.kind == 'room.stop_requested' &&
              event.sequence > continued.single.sequence &&
              event.cancelId.isNotEmpty,
        ),
        isTrue,
      );
      expect(
        finalLog.where((event) => event.kind == 'room.continued'),
        hasLength(1),
      );
      final finalReplies = finalLog
          .where(
            (event) =>
                event.kind == 'message.member' &&
                event.discussionEventId == continuation.discussionEventId,
          )
          .length;
      expect(finalReplies, lessThanOrEqualTo(4 * runtime.maxRounds!));
      owned.receipt['final_member_replies'] = finalReplies;
      await captureJourney(tester, 'prod-group-continue-stopped');
      owned.receipt['continue_phase'] = 'one grant confirmed then stopped';
    });
  });

  testWidgets('Production N07 stops an owned scheduled execution', (
    tester,
  ) async {
    await _journey(tester, 'task-stop', (owned) async {
      final task = await owned.createTask(
        'stop',
        'Without tools, files, network or delegation, print integers 1 through '
            '5000, one per line. This is isolated QA and may be interrupted.',
      );
      final controller = await _showTasks(tester, owned);
      await _tap(tester, find.text(task.name));
      await waitForProductionState(
        tester,
        () => find.byType(AdminScheduledTaskDetailPage).evaluate().isNotEmpty,
        'Owned execution detail opens',
      );
      await _tap(tester, find.byTooltip('Run now'));
      final stopRun = find
          .byWidgetPredicate(
            (widget) =>
                widget is IconButton &&
                widget.tooltip == 'Stop run' &&
                widget.onPressed != null,
          )
          .hitTestable();
      await waitForProductionState(
        tester,
        () =>
            controller.task(task.id)?.running == true &&
            stopRun.evaluate().length == 1,
        'Real owned task run is in flight and its Stop action is enabled',
      );
      final execution = controller.task(task.id)!.liveExecution!.id;
      // Trigger readback can publish running before its command guard clears.
      // A disabled icon is hit-testable, but tapping it dispatches nothing.
      await _tap(tester, stopRun);
      await captureJourney(tester, 'prod-task-stop-requested');
      await waitForProductionState(
        tester,
        () =>
            controller.task(task.id)?.latestExecution?.id == execution &&
            controller.task(task.id)?.latestExecution?.status == 'cancelled' &&
            controller.task(task.id)?.running == false,
        'Exact execution becomes cancelled after Stop',
        seconds: 180,
      );
      final saved = await owned.readOwnedExecution(task.id);
      expect(saved.latestExecution!.id, execution);
      expect(saved.latestExecution!.status, 'cancelled');
      expect(saved.enabled, isTrue, reason: 'Stop must not pause the schedule');
      await captureJourney(tester, 'prod-task-stop-confirmed');
      owned.receipt['cancelled_execution_id'] = execution;
    });
  });
}
