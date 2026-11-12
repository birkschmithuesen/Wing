import 'package:wing/core/models/profile_session_key.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/scheduled_task_detail_session.dart';
import 'package:wing/core/services/scheduled_tasks_controller.dart';
import 'package:wing/core/services/scheduled_tasks_repository.dart';

import 'support/scheduled_tasks_fixture.dart';

class _ManualTimer implements Timer {
  _ManualTimer(this.callback);
  final void Function(Timer) callback;
  @override
  bool isActive = true;
  @override
  int tick = 0;
  void fire() {
    if (isActive) {
      tick++;
      callback(this);
    }
  }

  @override
  void cancel() {
    isActive = false;
  }
}

void main() {
  late ScheduledTasksFixture fixture;
  late ScheduledTasksController controller;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    fixture = ScheduledTasksFixture();
    controller = ScheduledTasksController(
      ScheduledTasksRepository(fixture.profile),
      await SharedPreferences.getInstance(),
    );
    await controller.refresh();
  });
  tearDown(() => controller.dispose());

  test(
    'bounded history paging retains rows when the next refresh fails',
    () async {
      fixture.runRows.clear();
      for (var i = 0; i < 22; i++) {
        fixture.runRows.add({
          'id': 'script-$i',
          'source': 'cron_output',
          'title': 'Script run',
          'is_active': false,
        });
      }
      final session = ScheduledTaskDetailSession(
        controller,
        controller.task('morning')!,
        isVisible: () => true,
        onOpenSession: (_) async {},
      );
      addTearDown(session.dispose);
      await session.refresh();
      expect(session.state.history, hasLength(20));
      expect(session.state.canShowMore, true);
      await session.showMore();
      expect(session.state.history, hasLength(22));
      expect(fixture.admin.requests.last.$3['limit'], '100');
      fixture.failRuns = true;
      await session.refresh();
      expect(session.state.history, hasLength(22));
      expect(session.state.error, isNotNull);
    },
  );

  test(
    'late history response cannot replace a newer captured task observation',
    () async {
      final first = Completer<Map<String, dynamic>>();
      final firstReadEntered = Completer<void>();
      final stock = ScheduledTasksFixture();
      var requests = 0;
      fixture.intercept = (method, path, query, body) {
        if (path.endsWith('/runs')) {
          if (++requests == 1) {
            firstReadEntered.complete();
            return first.future;
          }
          return Future.value({
            'runs': [
              {'id': 'new', 'source': 'cron_output', 'title': 'New'},
            ],
          });
        }
        return stock.send(method, path, query, body);
      };
      final session = ScheduledTaskDetailSession(
        controller,
        controller.task('morning')!,
        isVisible: () => true,
        onOpenSession: (_) async {},
      );
      addTearDown(session.dispose);
      final old = session.refresh();
      await firstReadEntered.future;
      await session.refresh();
      first.complete({
        'runs': [
          {'id': 'old', 'source': 'cron_output', 'title': 'Old'},
        ],
      });
      await old;
      expect(session.state.history!.single.id, 'new');
    },
  );

  test(
    'only observed conversation rows open the captured profile session',
    () async {
      ProfileSessionKey? opened;
      final session = ScheduledTaskDetailSession(
        controller,
        controller.task('morning')!,
        isVisible: () => true,
        onOpenSession: (key) async {
          opened = key;
        },
      );
      addTearDown(session.dispose);
      await session.refresh();
      await session.open(session.state.history!.single);
      expect(opened!.workspace, fixture.profile.scope);
      expect(opened!.sessionId, 'cron_morning_123');
    },
  );

  test(
    'list refresh polling uses visible/resumed facts and stops on dispose',
    () async {
      late _ManualTimer timer;
      Duration? interval;
      var visible = false;
      final observation = ScheduledTasksObservation(
        controller,
        isVisible: () => visible,
        timer: (duration, callback) {
          interval = duration;
          return timer = _ManualTimer(callback);
        },
      );
      addTearDown(observation.dispose);
      final before = fixture.admin.requests.length;
      timer.fire();
      expect(fixture.admin.requests, hasLength(before));
      visible = true;
      observation.resumed(false);
      timer.fire();
      expect(fixture.admin.requests, hasLength(before));
      observation.resumed(true);
      await Future<void>.delayed(Duration.zero);
      expect(fixture.admin.requests.length, greaterThan(before));
      expect(interval, const Duration(seconds: 30));
      observation.dispose();
      final after = fixture.admin.requests.length;
      timer.fire();
      expect(fixture.admin.requests, hasLength(after));
      expect(timer.isActive, false);
    },
  );
}
