enum SessionGoalStatus { active, done, paused }

enum SessionGoalVerdict { blocked, continueRunning, done, skipped, wait }

enum SessionGoalWaitType { until, session, pid }

enum SessionControlAction {
  goalPause('goal.pause'),
  goalResume('goal.resume'),
  goalClear('goal.clear'),
  goalUnwait('goal.unwait'),
  loopPause('loop.pause'),
  loopResume('loop.resume'),
  loopStop('loop.stop'),
  subgoalAdd('subgoal.add'),
  subgoalRemove('subgoal.remove'),
  subgoalClear('subgoal.clear'),
  heartbeatPause('heartbeat.pause'),
  heartbeatResume('heartbeat.resume'),
  heartbeatClear('heartbeat.clear');

  final String wireValue;

  const SessionControlAction(this.wireValue);
}

class SessionGoalContract {
  final String outcome;
  final String verification;
  final String constraints;
  final String boundaries;
  final String stopWhen;

  const SessionGoalContract({
    required this.outcome,
    required this.verification,
    required this.constraints,
    required this.boundaries,
    required this.stopWhen,
  });
}

class SessionGoalGate {
  final String command;
  final int timeoutSeconds;
  final int maxRetries;
  final int attempts;
  final int? lastExitCode;

  const SessionGoalGate({
    required this.command,
    required this.timeoutSeconds,
    required this.maxRetries,
    required this.attempts,
    required this.lastExitCode,
  });
}

class SessionGoalWaitBarrier {
  final SessionGoalWaitType type;
  final String reason;
  final num? untilAt;
  final String? sessionTarget;
  final int? processId;

  const SessionGoalWaitBarrier._({
    required this.type,
    required this.reason,
    this.untilAt,
    this.sessionTarget,
    this.processId,
  });

  factory SessionGoalWaitBarrier.until({
    required num untilAt,
    required String reason,
  }) => SessionGoalWaitBarrier._(
    type: SessionGoalWaitType.until,
    reason: reason,
    untilAt: untilAt,
  );

  factory SessionGoalWaitBarrier.session({
    required String target,
    required String reason,
  }) => SessionGoalWaitBarrier._(
    type: SessionGoalWaitType.session,
    reason: reason,
    sessionTarget: target,
  );

  factory SessionGoalWaitBarrier.pid({
    required int target,
    required String reason,
  }) => SessionGoalWaitBarrier._(
    type: SessionGoalWaitType.pid,
    reason: reason,
    processId: target,
  );
}

class SessionGoal {
  final String title;
  final SessionGoalStatus status;
  final int turnsUsed;
  final int maxTurns;
  final SessionGoalContract contract;
  final List<String> subgoals;
  final List<SessionGoalGate> gates;
  final num? createdAt;
  final num? updatedAt;
  final String? pausedReason;
  final SessionGoalVerdict? lastVerdict;
  final String? lastReason;
  final SessionGoalWaitBarrier? waitBarrier;

  const SessionGoal({
    required this.title,
    required this.status,
    required this.turnsUsed,
    required this.maxTurns,
    required this.contract,
    required this.subgoals,
    required this.gates,
    this.createdAt,
    this.updatedAt,
    this.pausedReason,
    this.lastVerdict,
    this.lastReason,
    this.waitBarrier,
  });
}

enum SessionLoopStatus { active, paused, done }

enum SessionLoopMode { interval, selfPaced }

enum SessionHeartbeatStatus { active, paused }

class SessionLoop {
  final String prompt;
  final SessionLoopStatus status;
  final SessionLoopMode mode;
  final num intervalSeconds;
  final num currentDelay;
  final int times;
  final int maxTicks;
  final int ticksFired;
  final num nextDueAt;
  final bool awaitingResponse;
  final bool deferredByGoal;
  final String? pausedReason;
  final String? lastStopReason;

  const SessionLoop({
    required this.prompt,
    required this.status,
    required this.mode,
    required this.intervalSeconds,
    required this.currentDelay,
    required this.times,
    required this.maxTicks,
    required this.ticksFired,
    required this.nextDueAt,
    required this.awaitingResponse,
    required this.deferredByGoal,
    this.pausedReason,
    this.lastStopReason,
  });
}

class SessionHeartbeat {
  final String prompt;
  final SessionHeartbeatStatus status;
  final num intervalSeconds;
  final int fireCount;

  const SessionHeartbeat({
    required this.prompt,
    required this.status,
    required this.intervalSeconds,
    required this.fireCount,
  });
}

class SessionControlSnapshot {
  final SessionGoal? goal;
  final SessionLoop? loop;
  final SessionHeartbeat? heartbeat;
  final String revision;
  final num updatedAt;

  const SessionControlSnapshot({
    required this.goal,
    this.loop,
    this.heartbeat,
    required this.revision,
    required this.updatedAt,
  });

  /// Parses the complete `session.control` response or its `control` object.
  /// A control object with no active goal (`goal: null`) is valid.
  static SessionControlSnapshot? parse(dynamic value) {
    final outer = _record(value);
    if (outer == null) return null;
    final control = outer['control'] is Map ? _record(outer['control']) : outer;
    if (control == null ||
        !control.containsKey('goal') ||
        control['goal'] is! Map && control['goal'] != null ||
        control['revision'] is! String ||
        control['updated_at'] is! num ||
        !(control['updated_at'] as num).isFinite) {
      return null;
    }
    final rawGoal = control['goal'];
    final goal = rawGoal == null ? null : _parseGoal(rawGoal);
    if (rawGoal != null && goal == null) return null;
    final loop = control.containsKey('loop')
        ? _parseLoop(control['loop'])
        : null;
    if (control.containsKey('loop') &&
        control['loop'] != null &&
        loop == null) {
      return null;
    }
    final heartbeat = control.containsKey('heartbeat')
        ? _parseHeartbeat(control['heartbeat'])
        : null;
    if (control.containsKey('heartbeat') &&
        control['heartbeat'] != null &&
        heartbeat == null) {
      return null;
    }
    return SessionControlSnapshot(
      goal: goal,
      loop: loop,
      heartbeat: heartbeat,
      revision: control['revision'] as String,
      updatedAt: control['updated_at'] as num,
    );
  }

  static SessionGoal? _parseGoal(dynamic value) {
    final map = _record(value);
    if (map == null ||
        !map.containsKey('title') ||
        !map.containsKey('status') ||
        !map.containsKey('turns_used') ||
        !map.containsKey('max_turns') ||
        !map.containsKey('contract') ||
        !map.containsKey('subgoals') ||
        !map.containsKey('gates') ||
        map['title'] is! String ||
        map['status'] is! String ||
        map['turns_used'] is! int ||
        map['max_turns'] is! int ||
        map['subgoals'] is! List ||
        !(map['subgoals'] as List).every((item) => item is String) ||
        map['gates'] is! List) {
      return null;
    }
    final status = _status(map['status'] as String);
    final contract = _parseContract(map['contract']);
    final gates = (map['gates'] as List).map(_parseGate).toList();
    if (status == null ||
        contract == null ||
        gates.any((gate) => gate == null)) {
      return null;
    }
    final barrier = map.containsKey('wait_barrier')
        ? _parseBarrier(map['wait_barrier'])
        : null;
    if (map.containsKey('wait_barrier') && barrier == null) return null;
    final verdict = map.containsKey('last_verdict')
        ? _verdict(map['last_verdict'])
        : null;
    if (map.containsKey('last_verdict') && verdict == null) return null;
    if (!_optionalString(map, 'paused_reason') ||
        !_optionalString(map, 'last_reason') ||
        !_optionalNumber(map, 'created_at') ||
        !_optionalNumber(map, 'updated_at')) {
      return null;
    }
    return SessionGoal(
      title: map['title'] as String,
      status: status,
      turnsUsed: map['turns_used'] as int,
      maxTurns: map['max_turns'] as int,
      contract: contract,
      subgoals: List<String>.unmodifiable(
        (map['subgoals'] as List).cast<String>(),
      ),
      gates: List<SessionGoalGate>.unmodifiable(gates.cast<SessionGoalGate>()),
      createdAt: map['created_at'] as num?,
      updatedAt: map['updated_at'] as num?,
      pausedReason: map['paused_reason'] as String?,
      lastVerdict: verdict,
      lastReason: map['last_reason'] as String?,
      waitBarrier: barrier,
    );
  }

  static SessionLoop? _parseLoop(dynamic value) {
    final map = _record(value);
    const required = [
      'prompt',
      'status',
      'mode',
      'interval_seconds',
      'current_delay',
      'times',
      'until',
      'max_ticks',
      'ticks_fired',
      'created_at',
      'last_fired_at',
      'next_due_at',
      'awaiting_response',
      'deferred_by_goal',
    ];
    if (map == null || required.any((key) => !map.containsKey(key))) {
      return null;
    }
    final status = switch (map['status']) {
      'active' => SessionLoopStatus.active,
      'paused' => SessionLoopStatus.paused,
      'done' => SessionLoopStatus.done,
      _ => null,
    };
    final mode = switch (map['mode']) {
      'interval' => SessionLoopMode.interval,
      'self_paced' => SessionLoopMode.selfPaced,
      _ => null,
    };
    if (status == null ||
        mode == null ||
        map['prompt'] is! String ||
        map['until'] is! String ||
        map['interval_seconds'] is! num ||
        !(map['interval_seconds'] as num).isFinite ||
        map['current_delay'] is! num ||
        !(map['current_delay'] as num).isFinite ||
        map['times'] is! int ||
        map['max_ticks'] is! int ||
        map['ticks_fired'] is! int ||
        map['created_at'] is! num ||
        !(map['created_at'] as num).isFinite ||
        map['last_fired_at'] is! num ||
        !(map['last_fired_at'] as num).isFinite ||
        map['next_due_at'] is! num ||
        !(map['next_due_at'] as num).isFinite ||
        map['awaiting_response'] is! bool ||
        map['deferred_by_goal'] is! bool ||
        !_optionalString(map, 'paused_reason') ||
        !_optionalString(map, 'last_stop_reason')) {
      return null;
    }
    return SessionLoop(
      prompt: map['prompt'] as String,
      status: status,
      mode: mode,
      intervalSeconds: map['interval_seconds'] as num,
      currentDelay: map['current_delay'] as num,
      times: map['times'] as int,
      maxTicks: map['max_ticks'] as int,
      ticksFired: map['ticks_fired'] as int,
      nextDueAt: map['next_due_at'] as num,
      awaitingResponse: map['awaiting_response'] as bool,
      deferredByGoal: map['deferred_by_goal'] as bool,
      pausedReason: map['paused_reason'] as String?,
      lastStopReason: map['last_stop_reason'] as String?,
    );
  }

  static SessionHeartbeat? _parseHeartbeat(dynamic value) {
    final map = _record(value);
    const required = [
      'prompt',
      'status',
      'interval_seconds',
      'created_at',
      'last_fired_at',
      'fire_count',
    ];
    if (map == null || required.any((key) => !map.containsKey(key))) {
      return null;
    }
    final status = switch (map['status']) {
      'active' => SessionHeartbeatStatus.active,
      'paused' => SessionHeartbeatStatus.paused,
      _ => null,
    };
    if (status == null ||
        map['prompt'] is! String ||
        map['interval_seconds'] is! num ||
        !(map['interval_seconds'] as num).isFinite ||
        map['created_at'] is! num ||
        !(map['created_at'] as num).isFinite ||
        map['last_fired_at'] is! num ||
        !(map['last_fired_at'] as num).isFinite ||
        map['fire_count'] is! int) {
      return null;
    }
    return SessionHeartbeat(
      prompt: map['prompt'] as String,
      status: status,
      intervalSeconds: map['interval_seconds'] as num,
      fireCount: map['fire_count'] as int,
    );
  }

  static SessionGoalContract? _parseContract(dynamic value) {
    final map = _record(value);
    const keys = [
      'outcome',
      'verification',
      'constraints',
      'boundaries',
      'stop_when',
    ];
    if (map == null || keys.any((key) => map[key] is! String)) {
      return null;
    }
    return SessionGoalContract(
      outcome: map['outcome'] as String,
      verification: map['verification'] as String,
      constraints: map['constraints'] as String,
      boundaries: map['boundaries'] as String,
      stopWhen: map['stop_when'] as String,
    );
  }

  static SessionGoalGate? _parseGate(dynamic value) {
    final map = _record(value);
    if (map == null ||
        !map.containsKey('command') ||
        !map.containsKey('timeout_seconds') ||
        !map.containsKey('max_retries') ||
        !map.containsKey('attempts') ||
        !map.containsKey('last_exit_code') ||
        map['command'] is! String ||
        map['timeout_seconds'] is! int ||
        map['max_retries'] is! int ||
        map['attempts'] is! int ||
        (map['last_exit_code'] != null && map['last_exit_code'] is! int)) {
      return null;
    }
    return SessionGoalGate(
      command: map['command'] as String,
      timeoutSeconds: map['timeout_seconds'] as int,
      maxRetries: map['max_retries'] as int,
      attempts: map['attempts'] as int,
      lastExitCode: map['last_exit_code'] as int?,
    );
  }

  static SessionGoalWaitBarrier? _parseBarrier(dynamic value) {
    final map = _record(value);
    if (map == null || map['type'] is! String || map['reason'] is! String) {
      return null;
    }
    switch (map['type']) {
      case 'until':
        if (!map.containsKey('until_at')) return null;
        return map['until_at'] is num && (map['until_at'] as num).isFinite
            ? SessionGoalWaitBarrier.until(
                untilAt: map['until_at'] as num,
                reason: map['reason'] as String,
              )
            : null;
      case 'session':
        if (!map.containsKey('target')) return null;
        return map['target'] is String
            ? SessionGoalWaitBarrier.session(
                target: map['target'] as String,
                reason: map['reason'] as String,
              )
            : null;
      case 'pid':
        if (!map.containsKey('target')) return null;
        return map['target'] is int
            ? SessionGoalWaitBarrier.pid(
                target: map['target'] as int,
                reason: map['reason'] as String,
              )
            : null;
      default:
        return null;
    }
  }

  static SessionGoalStatus? _status(String value) => switch (value) {
    'active' => SessionGoalStatus.active,
    'done' => SessionGoalStatus.done,
    'paused' => SessionGoalStatus.paused,
    _ => null,
  };

  static SessionGoalVerdict? _verdict(dynamic value) => switch (value) {
    'blocked' => SessionGoalVerdict.blocked,
    'continue' => SessionGoalVerdict.continueRunning,
    'done' => SessionGoalVerdict.done,
    'skipped' => SessionGoalVerdict.skipped,
    'wait' => SessionGoalVerdict.wait,
    _ => null,
  };

  static bool _optionalString(Map<String, dynamic> map, String key) =>
      !map.containsKey(key) || map[key] is String;

  static bool _optionalNumber(Map<String, dynamic> map, String key) =>
      !map.containsKey(key) || (map[key] is num && (map[key] as num).isFinite);

  static Map<String, dynamic>? _record(dynamic value) => value is Map
      ? value.map((key, item) => MapEntry(key.toString(), item))
      : null;
}
