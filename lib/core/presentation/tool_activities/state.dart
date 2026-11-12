part of '../tool_activity_details.dart';

void _hindsightRetain(_ToolProjection p) {
  p.addRequest('Submitted memory', p.args['content'], copyable: true);
  p.options(p.args, {
    'context': 'Context',
    'tags': 'Tags',
    'occurred_at': 'Occurred',
  });
  // The receipt confirms what the provider reported. Submitted prose is not
  // evidence of which facts Hindsight extracted or consolidated.
  if (p.output is String) {
    p.addResponse('Result', p.output, copyable: true);
  } else {
    for (final key in ['result', 'text', 'content', 'output', 'message']) {
      if (p.data[key] is String) {
        p.addResponse('Result', p.data[key], copyable: true);
        break;
      }
    }
  }
}

void _memory(_ToolProjection p) {
  p.options(p.args, {'target': 'Store', 'action': 'Action'});
  final operations = _maps(p.args['operations']);
  if (operations.isEmpty) {
    _memoryRequest(p, p.args, const []);
  } else {
    for (var index = 0; index < operations.length; index++) {
      _memoryRequest(p, operations[index], [
        'Operation ${index + 1}',
        ?_text(operations[index]['action']),
      ]);
    }
  }
  p.fact('Entries', p.data['entry_count'], result: true);
  p.fact('Capacity', p.data['usage'], result: true);
  p.addResponse('Result', p.data['message']);
  for (final key in ['replaced_entry', 'removed_entry']) {
    p.addResponse(
      key == 'replaced_entry' ? 'Previous entry' : 'Removed entry',
      p.data[key],
      copyable: true,
    );
  }
  for (final key in ['replaced_entries', 'removed_entries']) {
    final entries = p.data[key];
    if (entries is! Map) continue;
    for (final entry in entries.entries) {
      p.addResponse(
        key == 'replaced_entries' ? 'Previous entry' : 'Removed entry',
        entry.value,
        copyable: true,
        facts: ['Operation ${entry.key}'],
      );
    }
  }
  if (p.data['staged'] == true) {
    p.status = 'Awaiting approval';
    if (_text(p.data['message']) == null) {
      p.addResponse('Result', 'Proposed write awaits approval.');
    }
  }
  for (final key in ['current_entries', 'closest_entries', 'matches']) {
    if (p.data[key] case final List entries) {
      for (final entry in entries) {
        p.addResponse(
          key == 'matches' ? 'Matching entry excerpt' : 'Current entry',
          entry,
          copyable: true,
        );
      }
    }
  }
  p.addResponse('Recovery', p.data['remediation']);
  final backup = _text(p.data['drift_backup']);
  if (backup != null) p.addResponse('Backup', backup, target: backup);
}

void _memoryRequest(_ToolProjection p, Map operation, List<String> facts) {
  p.addRequest(
    'Entry matching',
    operation['old_text'],
    copyable: true,
    facts: facts,
  );
  // Both slots are advertised by current stock; content takes precedence when nonempty.
  final content = operation['content'];
  final value = content is String && content.isNotEmpty
      ? content
      : operation['new_text'];
  p.addRequest(
    operation['action'] == 'replace' ? 'New whole entry' : 'Memory',
    value,
    copyable: true,
    facts: facts,
  );
}

void _skillView(_ToolProjection p) {
  p.intent = _text(p.args['name']);
  p.options(p.args, {'file_path': 'File'});
  final data = p.data;
  if (data['status'] == 'unchanged') {
    p.status = 'Unchanged';
    p.addResponse(
      'Result',
      data['message'] ?? 'Skill unchanged; no content returned.',
    );
  } else if (data['is_binary'] == true) {
    p.addResponse(
      'Result',
      data['content'],
      facts: const ['Binary file receipt'],
    );
  } else {
    final file = _text(data['file']) ?? _text(p.args['file_path']);
    final literal = file != null && !_stateMarkdownPath(file);
    final content = data['content'];
    // The main skill's YAML declaration is catalog metadata, not its prose.
    // Keep the exact received file in raw viewing/copying.
    final mainSkill = file == null || file.split('/').last == 'SKILL.md';
    final document =
        mainSkill &&
            content is String &&
            data['success'] != false &&
            _text(data['error']) == null
        ? SkillDocument.fromReceived(
            name: _text(data['name']) ?? p.intent ?? 'Skill',
            content: content,
            description: _text(data['description']),
            tags: data['tags'] is List
                ? (data['tags'] as List).whereType<String>().where(
                    (tag) => tag.trim().isNotEmpty,
                  )
                : null,
            metadata: data['metadata'] is Map ? data['metadata'] as Map : null,
            sourcePath: _text(data['_source_path']),
          )
        : null;
    if (document != null) {
      final block = ToolDetailBlock(
        label: 'Result',
        text: document.formattedContent,
        markdown: true,
        role: ToolDetailRole.skill,
        copyable: true,
        exactCopyText: content as String,
        resourceTarget: document.sourcePath,
        showEmpty: true,
      );
      p.response.add(block);
      p.skill = SkillActivityDocument(document: document, content: block);
    } else {
      p.addResponse(
        'Result',
        content,
        format: literal ? ToolDetailFormat.source : ToolDetailFormat.prose,
        role: literal ? ToolDetailRole.code : ToolDetailRole.skill,
        markdown: !literal,
        copyable: true,
        exactCopyText: content is String ? content : null,
        target: _text(data['_source_path']),
      );
    }
  }
  for (final key in ['setup_note', 'gateway_setup_hint', 'deps_note']) {
    p.warning(data[key], label: 'Setup');
  }
  // Missing dependencies matter; empty declarations and routine readiness booleans do not.
  for (final key in [
    'missing_required_environment_variables',
    'missing_credential_files',
  ]) {
    final value = data[key];
    if (value is List && value.isNotEmpty) {
      p.warning(
        value.map(_display).join(' · '),
        label: key == 'missing_credential_files'
            ? 'Missing credential files'
            : 'Missing environment variables',
      );
    }
  }
  if (data['setup_needed'] == true) p.addResponse('Setup', data['setup_help']);
  if (_text(data['error']) != null) {
    _stateRecovery(p, data, [
      'available_skills',
      'available_files',
      'load_names',
    ]);
    p.addResponse('Recovery', data['hint']);
  }
  _statePlainReceipt(p);
}

void _skillManage(_ToolProjection p) {
  final operations = _maps(p.args['operations']);
  final results = _maps(p.data['results']);
  final names = (operations.isEmpty ? results : operations)
      .map((operation) => _text(operation['name']))
      .whereType<String>()
      .toSet();
  if (names.isNotEmpty) p.intent = names.join(' · ');
  for (var index = 0; index < operations.length; index++) {
    final operation = operations[index];
    final name = _text(operation['name']);
    if (operations.length == 1) p.intent = name;
    final facts = <String>[
      if (operations.length > 1) 'Operation ${index + 1}',
      ?_text(operation['action']),
      ?_text(operation['file_path']),
      if (_text(operation['category']) case final value?) 'Category: $value',
      if (operation['replace_all'] == true) 'Replace all',
      if (_text(operation['absorbed_into']) case final value?)
        'Absorbed into: $value',
    ];
    p.addRequest(
      name ?? 'Request',
      operation['content'] ?? operation['file_content'],
      format: operation['content'] is String
          ? ToolDetailFormat.prose
          : ToolDetailFormat.source,
      role: operation['content'] is String
          ? ToolDetailRole.skill
          : ToolDetailRole.code,
      markdown: operation['content'] is String,
      copyable: true,
      facts: facts,
    );
    p.addRequest(
      name ?? 'Skill',
      operation['old_string'],
      format: ToolDetailFormat.source,
      role: ToolDetailRole.code,
      copyable: true,
      facts: ['Find', ...facts],
    );
    p.addRequest(
      'Replace with',
      operation['new_string'],
      format: ToolDetailFormat.source,
      role: ToolDetailRole.code,
      copyable: operation['new_string'] != '',
      facts: [?name, ...facts],
    );
    if (operation['content'] is! String &&
        operation['file_content'] is! String &&
        operation['old_string'] is! String) {
      for (final fact in [?name, ...facts]) {
        if (!p.headerFacts.contains(fact)) p.headerFacts.add(fact);
      }
    }
  }
  p.fact('Operations applied', p.data['operations_applied'], result: true);
  p.addResponse('Result', p.data['message']);
  for (final result in results) {
    final name = _text(result['name']);
    final file = _text(result['file_path']);
    final action = _text(result['action']);
    final confirmed =
        p.data['success'] == true &&
        result['success'] == true &&
        p.data['staged'] != true;
    final outcome = p.data['staged'] == true
        ? 'Awaiting approval'
        : p.data['success'] == false
        ? 'Batch failed'
        : result['success'] == false
        ? 'Failed'
        : !confirmed
        ? 'Outcome unconfirmed'
        : switch (action) {
            'create' => 'Created',
            'edit' => 'Updated',
            'patch' => 'Patched',
            'delete' => 'Deleted',
            'write_file' => 'Written',
            'remove_file' => 'Removed',
            _ => 'Reported operation completed',
          };
    if (name != null || file != null || action != null) {
      p.response.add(
        ToolDetailBlock(
          label: name ?? 'Skill operation',
          text: outcome,
          filenameTarget: file,
          facts: [
            if (!confirmed && action != null) 'Requested action: $action',
          ],
        ),
      );
    }
    _stateLint(
      p,
      result,
      facts: [?_text(result['name']), ?_text(result['file_path'])],
    );
  }
  _stateLint(p, p.data);
  if (p.data['staged'] == true) {
    p.status = 'Awaiting approval';
    if (_text(p.data['message']) == null) {
      p.addResponse('Result', 'Proposed changes await approval.');
    }
  }
  if (p.data['failed_index'] case final int index when index >= 0) {
    p.fact('Failed operation', index + 1, result: true);
  }
  p.fact(
    'Operations attempted before failure',
    p.data['completed_before_failure'],
    result: true,
  );
  p.addResponse(
    'File excerpt',
    p.data['file_preview'],
    format: ToolDetailFormat.source,
    role: ToolDetailRole.code,
    copyable: true,
    facts: const ['Received excerpt'],
  );
  if (_text(p.data['error']) != null) {
    _stateRecovery(p, p.data, ['available_files']);
  }
  _statePlainReceipt(p);
}

void _stateLint(_ToolProjection p, Map data, {List<String> facts = const []}) {
  for (final finding in _maps(data['lint_warnings'])) {
    final text = _text(finding['message']);
    if (text == null) continue;
    p.addResponse(
      'Authoring warning',
      text,
      role: ToolDetailRole.warning,
      facts: [...facts, ?_text(finding['rule'])],
    );
    if (p.state != ToolReceiptState.error) {
      p.state = ToolReceiptState.warning;
      p.status ??= 'Completed with a warning';
    }
  }
}

void _todoList(_ToolProjection p) {
  p.intent = p.args['todos'] is List
      ? (p.args['todos'] as List).isEmpty
            ? 'Clear tasks'
            : p.args['merge'] == true
            ? 'Update tasks'
            : 'Set tasks'
      : 'Read tasks';
  final summary = p.data['summary'];
  if (summary is Map) {
    for (final key in [
      'total',
      'pending',
      'in_progress',
      'completed',
      'cancelled',
    ]) {
      p.fact(
        key == 'total' ? 'Tasks' : _stateStatus(key),
        summary[key],
        result: true,
      );
    }
  }
  final tasks = _maps(p.data['todos']);
  if (p.data['todos'] is List && tasks.isEmpty) {
    p.addResponse('Result', 'No tasks.');
  }
  // These are immutable observations; no checkbox or receipt grants editing authority.
  for (final task in tasks) {
    p.addResponse(
      'Task',
      task['content'],
      role: ToolDetailRole.task,
      facts: [
        if (_text(task['status']) case final status?) _stateStatus(status),
        if (_text(task['parent']) case final parent?) 'Parent: $parent',
      ],
    );
  }
  _statePlainReceipt(p);
}

void _delegateTask(_ToolProjection p) {
  p.options(p.args, {'action': 'Action'});
  final tasks = _maps(p.args['tasks']);
  for (var index = 0; index < tasks.length; index++) {
    final task = tasks[index];
    final facts = [
      if (tasks.length > 1) 'Task ${index + 1}',
      if (_text(task['group']) case final group?) 'Group: $group',
    ];
    p.addRequest(
      'Task',
      task['goal'],
      role: ToolDetailRole.task,
      markdown: true,
      copyable: true,
      facts: facts,
    );
    p.addRequest(
      'Context',
      task['context'],
      markdown: true,
      copyable: true,
      facts: facts,
    );
    if (task['output_schema'] != null) {
      p.headerFacts.add('Task ${index + 1}: declared output schema');
    }
    if (task['images'] case final List images) {
      for (final image in images) {
        p.image('Task ${index + 1} image', image);
      }
    }
  }
  p.addRequest('Steering', p.args['message'], copyable: true);
  if (p.data['status'] == 'dispatched') {
    p.status = 'Dispatched in background';
    p.addResponse('Result', 'Dispatched in background.');
    p.fact('Tasks dispatched', p.data['count'], result: true);
    // When saved input is unavailable, these are genuine returned goals, not guessed intent.
    if (tasks.isEmpty) {
      if (p.data['goals'] case final List goals) {
        for (final goal in goals) {
          p.addResponse('Task', goal, role: ToolDetailRole.task);
        }
      }
    }
  } else if (p.data['status'] == 'queued') {
    p.status = 'Steering queued';
    p.addResponse(
      'Result',
      'Steering queued; delivery to the child is pending.',
    );
  } else if (p.data['status'] == 'interrupt_requested') {
    p.status = 'Interruption requested';
    p.addResponse(
      'Result',
      'Interruption requested; the child may still be stopping.',
    );
  }
  for (final result in [
    ..._maps(p.data['results']),
    ..._maps(p.data['inline_results']),
  ]) {
    _stateDelegateResult(p, result);
  }
  p.fact(
    'Total duration (seconds)',
    p.data['total_duration_seconds'],
    result: true,
  );
  for (final child in _maps(p.data['subagents'])) {
    p.addResponse(
      'Task',
      child['goal'],
      role: ToolDetailRole.task,
      facts: [
        if (_text(child['status']) case final status?) _stateStatus(status),
        if (_text(child['parent_id']) case final parent?) 'Parent: $parent',
        ?_text(child['model']),
      ],
    );
  }
  if (p.data['action'] == 'list' &&
      p.data['subagents'] is List &&
      (p.data['subagents'] as List).isEmpty) {
    p.addResponse('Result', 'No live subagents.');
  }
  if (p.data['process_notes'] case final List notes) {
    for (final note in notes) {
      p.warning(note, label: 'Processes');
    }
  }
  // Dispatch/control notes are already represented by qualified receipt facts.
  if (p.data['results'] is List && p.data['status'] != 'dispatched') {
    p.addResponse('Execution context', p.data['note']);
  }
  _statePlainReceipt(p);
}

void _stateDelegateResult(_ToolProjection p, Map result) {
  final facts = <String>[
    if (result['task_index'] case final int index when index >= 0)
      'Task ${index + 1}',
    if (_text(result['status']) case final status?) _stateStatus(status),
    ?_text(result['model']),
    if (result['duration_seconds'] case final num duration) '${duration}s',
  ];
  p.addResponse(
    'Result',
    _text(result['summary']) ??
        (_text(result['status']) == 'completed'
            ? 'No result returned'
            : 'No result received'),
    role: ToolDetailRole.output,
    markdown: true,
    copyable: _text(result['summary']) != null,
    facts: facts,
  );
  if (result['truncated'] == true ||
      result['exit_reason'] == 'max_iterations') {
    p.warning(
      'Iteration budget ended; the returned summary may be partial.',
      label: 'Partial result',
    );
  }
  if (result['summary_truncated'] == true) {
    p.warning('The backend shortened this summary.', label: 'Partial result');
    final fullPath = _text(result['summary_full_path']);
    if (fullPath != null) {
      p.addResponse('Full summary', fullPath, target: fullPath);
    }
  }
  if (result['schema_valid'] == false) {
    p.warning(
      result['schema_note'] ??
          'Returned text does not satisfy the declared output schema.',
      label: 'Unvalidated result',
    );
    if (result['schema_errors'] case final List errors) {
      for (final error in errors) {
        p.addResponse('Schema finding', error, role: ToolDetailRole.warning);
      }
    }
  }
  final error = _text(result['error']);
  final status = _text(result['status']);
  if (error != null) p.warning(error, label: 'Child result');
  if (const ['failed', 'error', 'timeout', 'interrupted'].contains(status)) {
    p.warning(
      error == null ? _stateStatus(status!) : null,
      label: 'Child result',
    );
    if (status != 'interrupted') {
      p.state = ToolReceiptState.error;
      p.status = 'Child failed';
    } else if (p.state != ToolReceiptState.error) {
      p.state = ToolReceiptState.warning;
      p.status = 'Interrupted';
    }
  }
  final missed = _text(result['missed_steer']);
  if (missed != null && !(_text(result['summary']) ?? '').contains(missed)) {
    p.warning(missed, label: 'Steering was not delivered');
  }
}

void _cronjobManage(_ToolProjection p) {
  p.intent = _text(p.args['name']);
  p.options(p.args, {
    'action': 'Action',
    'job_id': 'Job',
    'schedule': 'Schedule',
    'repeat': 'Repeat',
    'deliver': 'Delivery',
    'failure_deliver': 'Failure delivery',
    'skills': 'Skills',
    'monitor': 'Monitor',
    'context_from': 'Context jobs',
    'enabled_toolsets': 'Tools',
    'workdir': 'Working directory',
  });
  p.addRequest(
    p.args['action'] == 'run' ? 'Extra context' : 'Prompt',
    p.args['prompt'],
    markdown: true,
    copyable: true,
  );
  p.addRequest(
    'Script',
    p.args['script'],
    format: ToolDetailFormat.source,
    role: ToolDetailRole.command,
  );
  if (p.args['no_agent'] == true) p.headerFacts.add('Script only');
  if (p.args['paused'] == true) p.headerFacts.add('Create paused');
  if (p.args['continuity'] == true) {
    p.headerFacts.add('Uses previous job output');
  }
  if (p.args['attach_to_session'] == true) {
    p.headerFacts.add('Continuable delivery');
  }
  if (p.args.containsKey('pinned')) p.fact('Model pinned', p.args['pinned']);
  p.addRequest('Pause reason', p.args['paused_reason']);
  if (p.data['job'] case final Map job) _stateCronJob(p, job);
  for (final job in _maps(p.data['jobs'])) {
    _stateCronJob(p, job);
  }
  if (p.data['jobs'] is List && (p.data['jobs'] as List).isEmpty) {
    p.addResponse('Result', 'No scheduled jobs.');
  }
  if (p.data['removed_job'] case final Map removed) {
    p.fact('Removed job', removed['name'], result: true);
    p.fact('Previous schedule', removed['schedule'], result: true);
  }
  if (p.data['forwarded_to_gateway'] == true) {
    p.status = 'Dispatched to gateway';
    p.addResponse(
      'Result',
      'Dispatched to the gateway; completion is pending.',
    );
  }
  p.addResponse('Result', p.data['message']);
  if (p.data['warning'] is String) p.warning(p.data['warning']);
  if (p.data['guidance'] case final List guidance) {
    for (final note in guidance) {
      p.addResponse('Job context', note);
    }
  }
  // Admission and asynchronous delivery notes must not read as completed job execution.
  p.addResponse('Execution context', p.data['note']);
  for (final match in _maps(p.data['matches'])) {
    p.addResponse(
      'Matching job',
      match['name'],
      facts: [?_text(match['id']), ?_text(match['schedule'])],
    );
  }
  _statePlainReceipt(p);
}

void _stateCronJob(_ToolProjection p, Map job) {
  final facts = <String>[
    ?_text(job['name']),
    for (final key in ['schedule', 'repeat', 'deliver'])
      if (_text(job[key]) case final value?) '${_stateCronLabel(key)}: $value',
    if (_text(job['state']) case final state?) _stateStatus(state),
  ];
  p.addResponse(
    'Prompt excerpt',
    job['prompt_preview'],
    markdown: true,
    copyable: true,
    facts: facts,
  );
  if (_text(job['prompt_preview']) == null) {
    for (final fact in facts) {
      if (!p.metadata.contains(fact)) p.metadata.add(fact);
    }
  }
  for (final key in ['next_run_at', 'last_run_at', 'last_status']) {
    p.fact(_stateCronLabel(key), job[key], result: true);
  }
  final script = _text(job['script']);
  if (script != null) {
    p.addResponse(
      'Script',
      script,
      format: ToolDetailFormat.source,
      role: ToolDetailRole.command,
      target: script,
    );
  }
  if (job['execution_mode'] == 'background') {
    p.status = 'Running in background';
    p.addResponse(
      'Result',
      'Job dispatched in the background; completion is pending.',
    );
  } else if (_text(job['execution_skipped']) case final reason?) {
    p.addResponse('Run skipped', reason);
    p.status = 'Run skipped';
  } else if (job['execution_success'] == false) {
    p.state = ToolReceiptState.error;
    p.status = 'Job execution failed';
    p.addResponse(
      'Execution error',
      job['execution_error'] ?? 'Job execution failed.',
      role: ToolDetailRole.warning,
    );
  } else if (job['execution_success'] == true) {
    p.addResponse('Result', 'Job execution completed.');
  }
  for (final key in ['last_delivery_error', 'last_fire_error', 'last_error']) {
    final error = _text(job[key]);
    if (error == null || p.response.any((block) => block.text == error)) {
      continue;
    }
    p.warning(
      error,
      label: key == 'last_delivery_error'
          ? 'Last delivery error'
          : 'Last job error',
    );
  }
  if (job['last_delivery_unverified'] == true) {
    p.warning('Delivery completion is unverified.', label: 'Delivery');
  }
  p.addResponse('Pause reason', job['paused_reason']);
}

String _stateCronLabel(String key) => switch (key) {
  'schedule' => 'Schedule',
  'repeat' => 'Repeat',
  'deliver' => 'Delivery',
  'next_run_at' => 'Next run',
  'last_run_at' => 'Last run',
  'last_status' => 'Last result',
  _ => key,
};

void _sessionSearch(_ToolProjection p) {
  final read = _text(p.args['session_id']) != null;
  if (!read) {
    p.addRequest(
      'Query',
      p.args['query'],
      role: ToolDetailRole.search,
      copyable: true,
    );
  }
  p.options(p.args, {
    'session_id': 'Session',
    'around_message_id': 'Anchor',
    'window': 'Window',
    'limit': 'Limit',
    'sort': 'Sort',
    'detail': 'Detail',
    'after': 'After',
    'before': 'Before',
    'role_filter': 'Roles',
    'profile': 'Profile',
    'exclude_session_ids': 'Excluded sessions',
  });
  final mode = _text(p.data['mode']);
  if (mode == 'read' || mode == 'scroll') {
    final meta = p.data['session_meta'];
    final facts = _stateSessionFacts(meta is Map ? meta : const {});
    p.headerFacts.addAll(facts);
    _stateSessionMessages(p, p.data['messages']);
    p.fact('Session messages', p.data['message_count'], result: true);
    p.fact('Messages before', p.data['messages_before'], result: true);
    p.fact('Messages after', p.data['messages_after'], result: true);
    if (p.data['truncated'] == true) {
      p.warning(
        p.data['message'] ?? 'Only the first and last messages were returned.',
        label: 'Partial session',
      );
    }
  } else if (mode == 'discover') {
    for (final hit in _maps(p.data['results'])) {
      final facts = _stateSessionFacts(hit);
      final seen = <Object>{};
      final messages = _maps(hit['messages']);
      if (messages.isEmpty) {
        p.addResponse('Result', hit['snippet'], copyable: true, facts: facts);
      }
      final windowIds = messages
          .map((message) => message['id'])
          .whereType<Object>()
          .toSet();
      final start = _maps(
        hit['bookend_start'],
      ).where((message) => !windowIds.contains(message['id'])).toList();
      _stateSessionMessages(p, start, facts: facts, seen: seen);
      _stateSessionMessages(p, messages, facts: facts, seen: seen);
      _stateSessionMessages(p, hit['bookend_end'], facts: facts, seen: seen);
      if (hit['detail'] == 'compact') {
        p.metadata.add('Only the matched message was returned.');
      }
    }
    p.fact('Sessions returned', p.data['count'], result: true);
    if (p.data['count'] == 0) {
      p.addResponse('Result', p.data['message'] ?? 'No matching sessions.');
    }
  } else if (mode == 'browse') {
    for (final hit in _maps(p.data['results'])) {
      p.addResponse(
        'Session excerpt',
        hit['preview'],
        copyable: true,
        facts: _stateSessionFacts(hit),
      );
      if (_text(hit['preview']) == null) p.addResponse('Session', hit['title']);
    }
    p.fact('Sessions returned', p.data['count'], result: true);
    if (p.data['count'] == 0) p.addResponse('Result', 'No recent sessions.');
  }
  if (p.data['index_rebuild'] case final Map rebuild) {
    p.warning(rebuild['note'], label: 'Incomplete search index');
  }
  p.warning(p.data['warning']);
  _statePlainReceipt(p);
}

List<String> _stateSessionFacts(Map session) => [
  ?_text(session['title']),
  ?_text(session['when']),
  ?_text(session['source']),
  if (_text(session['parent_session_id']) case final parent?)
    'Parent session: $parent',
];

void _stateSessionMessages(
  _ToolProjection p,
  Object? value, {
  List<String> facts = const [],
  Set<Object>? seen,
}) {
  for (final message in _maps(value)) {
    final id = message['id'];
    if (id != null && seen != null && !seen.add(id)) continue;
    final text = _text(message['content']);
    final role = _text(message['role']);
    final context = [
      ...facts,
      ?role,
      if (message['anchor'] == true) 'Matched message',
      if (message['content_truncated'] == true) 'Received excerpt',
    ];
    if (text != null) {
      p.addResponse(
        'Message',
        message['content'],
        facts: context,
        role: role == 'tool' ? ToolDetailRole.output : ToolDetailRole.text,
        format: role == 'tool'
            ? ToolDetailFormat.source
            : ToolDetailFormat.prose,
        markdown: role != 'tool',
        copyable: true,
      );
    } else {
      // A tool-call-only turn is real evidence, but absent prose is not a missing summary.
      for (final call in _maps(message['tool_calls'])) {
        if (call['function'] case final Map function) {
          p.addResponse('Tool requested', function['name'], facts: context);
        }
      }
    }
  }
}

void _stateRecovery(_ToolProjection p, Map data, List<String> keys) {
  for (final key in keys) {
    final value = data[key];
    if (value is List && value.isNotEmpty) {
      p.addResponse('Available choices', value.map(_display).join('\n'));
    }
    if (value is Map) {
      final choices = value.values
          .whereType<List>()
          .expand((v) => v)
          .map(_display)
          .toList();
      if (choices.isNotEmpty) {
        p.addResponse('Available files', choices.join('\n'));
      }
    }
  }
}

void _statePlainReceipt(_ToolProjection p) {
  if (p.output is String && p.response.isEmpty) {
    p.addResponse('Result', p.output);
  }
}

bool _stateMarkdownPath(String path) =>
    RegExp(r'\.(md|markdown)$', caseSensitive: false).hasMatch(path);
String _stateStatus(String status) => switch (status) {
  'in_progress' => 'In progress',
  'pending' => 'Pending',
  'completed' => 'Completed',
  'cancelled' => 'Cancelled',
  'failed' => 'Failed',
  'error' => 'Error',
  'timeout' => 'Timed out',
  'interrupted' => 'Interrupted',
  'dispatched' => 'Dispatched',
  'scheduled' => 'Scheduled',
  'paused' => 'Paused',
  'done' => 'Done',
  _ => status.replaceAll('_', ' '),
};
