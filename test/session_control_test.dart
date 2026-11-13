import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/session_control.dart';

void main() {
  Map<String, dynamic> goal({
    String status = 'active',
    dynamic barrier,
    dynamic verdict,
  }) => {
    'title': 'Ship D24',
    'status': status,
    'turns_used': 2,
    'max_turns': 8,
    'contract': <String, dynamic>{
      'outcome': 'A useful release',
      'verification': 'Run the checks',
      'constraints': 'Keep scope bounded',
      'boundaries': 'No unrelated changes',
      'stop_when': 'Checks pass',
    },
    'subgoals': ['Implement model', 'Review details'],
    'gates': [
      {
        'command': 'flutter analyze',
        'timeout_seconds': 30,
        'max_retries': 1,
        'attempts': 0,
        'last_exit_code': null,
      },
    ],
    'wait_barrier': ?barrier,
    'last_verdict': ?verdict,
  };

  test('parses full server control response and typed details', () {
    final snapshot = SessionControlSnapshot.parse({
      'control': {
        'goal': goal(
          status: 'paused',
          verdict: 'wait',
          barrier: {
            'type': 'session',
            'target': 'other-session',
            'reason': 'Waiting for dependency',
          },
        ),
        'revision': 'opaque-sha',
        'updated_at': 123.5,
      },
    });

    expect(snapshot, isNotNull);
    expect(snapshot!.revision, 'opaque-sha');
    expect(snapshot.goal!.status, SessionGoalStatus.paused);
    expect(snapshot.goal!.contract.verification, 'Run the checks');
    expect(snapshot.goal!.subgoals, ['Implement model', 'Review details']);
    expect(snapshot.goal!.gates.single.command, 'flutter analyze');
    expect(snapshot.goal!.waitBarrier!.sessionTarget, 'other-session');
    expect(snapshot.goal!.lastVerdict, SessionGoalVerdict.wait);
  });

  test('accepts a valid empty goal snapshot', () {
    final snapshot = SessionControlSnapshot.parse({
      'control': {'goal': null, 'revision': '', 'updated_at': 0},
    });
    expect(snapshot, isNotNull);
    expect(snapshot!.goal, isNull);
  });

  test('parses loop and heartbeat snapshots with nullable controls', () {
    final snapshot = SessionControlSnapshot.parse({
      'control': {
        'goal': null,
        'revision': 'background-r',
        'updated_at': 10,
        'loop': {
          'prompt': 'Check status',
          'status': 'paused',
          'mode': 'self_paced',
          'interval_seconds': 60,
          'current_delay': 90.5,
          'times': 3,
          'until': 'done',
          'max_ticks': 10,
          'ticks_fired': 3,
          'created_at': 1,
          'last_fired_at': 8,
          'next_due_at': 100,
          'awaiting_response': false,
          'deferred_by_goal': true,
          'paused_reason': 'User paused',
          'last_stop_reason': 'manual',
        },
        'heartbeat': {
          'prompt': 'Ping',
          'status': 'active',
          'interval_seconds': 30,
          'created_at': 2,
          'last_fired_at': 9,
          'fire_count': 4,
        },
      },
    });
    expect(snapshot!.loop!.mode, SessionLoopMode.selfPaced);
    expect(snapshot.loop!.deferredByGoal, isTrue);
    expect(snapshot.loop!.currentDelay, 90.5);
    expect(snapshot.heartbeat!.status, SessionHeartbeatStatus.active);
    expect(snapshot.heartbeat!.fireCount, 4);
  });

  for (final entry in <String, Map<String, dynamic>>{
    'absent': {},
    'null': {'loop': null, 'heartbeat': null},
  }.entries) {
    test('accepts ${entry.key} background controls', () {
      final snapshot = SessionControlSnapshot.parse({
        'control': {
          'goal': null,
          'revision': 'r',
          'updated_at': 0,
          ...entry.value,
        },
      });
      expect(snapshot, isNotNull);
      expect(snapshot!.loop, isNull);
      expect(snapshot.heartbeat, isNull);
    });
  }
  test('rejects incomplete background loop', () {
    expect(
      SessionControlSnapshot.parse({
        'control': {
          'goal': null,
          'revision': 'r',
          'updated_at': 0,
          'loop': {'status': 'active'},
        },
      }),
      isNull,
    );
  });

  test('keeps additive server fields instead of hiding the goal', () {
    final value = goal()..['future_field'] = {'new': true};
    (value['contract'] as Map<String, dynamic>)['future_contract_field'] = 1;
    final snapshot = SessionControlSnapshot.parse({
      'control': {'goal': value, 'revision': 'r', 'updated_at': 0},
    });
    expect(snapshot!.goal!.title, 'Ship D24');
  });

  for (final entry in <String, Map<String, dynamic>>{
    'unsupported goal status': {
      'goal': goal(status: 'running'),
      'revision': 'r',
      'updated_at': 1,
    },
    'unsupported barrier': {
      'goal': goal(barrier: {'type': 'pid', 'target': '42', 'reason': 'x'}),
      'revision': 'r',
      'updated_at': 1,
    },
    'missing snapshot metadata': {'goal': null},
    'missing goal': {'revision': 'r', 'updated_at': 1},
  }.entries) {
    test('rejects ${entry.key}', () {
      expect(SessionControlSnapshot.parse({'control': entry.value}), isNull);
    });
  }
}
