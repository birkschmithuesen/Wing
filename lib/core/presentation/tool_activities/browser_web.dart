part of '../tool_activity_details.dart';

void _browserWarnings(_ToolProjection p) {
  for (final key in const [
    'warning',
    'bot_detection_warning',
    'fallback_warning',
    'stealth_warning',
  ]) {
    p.warning(p.data[key]);
  }
  if (p.data['used_real_profile'] == true) {
    p.metadata.add('Used real browser profile');
  }
  final remoteView = _web(p.data['vnc_url']);
  if (remoteView != null) {
    p.addResponse(
      'Remote browser',
      _text(p.data['vnc_hint']) ?? 'View the remote browser.',
      link: remoteView,
    );
  }
}

void _browserResource(_ToolProjection p, {bool preferPath = false}) {
  p.resourceTarget = preferPath
      ? _text(p.data['path']) ?? _text(p.data['url'])
      : _text(p.data['url']);
  p.fact('Page', p.data['title']);
}

void _browserSnapshotPayload(_ToolProjection p) {
  final snapshot = _text(p.data['snapshot']);
  final partial =
      snapshot != null &&
      RegExp(
        r'\[\.\.\. \d+ more lines truncated(?: — full snapshot: read_file path="[^"\n]+" offset=\d+ limit=200|, use browser_snapshot for full content)\]\s*$',
      ).hasMatch(snapshot);
  p.addResponse(
    'Page content',
    snapshot,
    format: ToolDetailFormat.source,
    role: ToolDetailRole.output,
    copyable: true,
    facts: [
      if (p.data['element_count'] is num)
        'Elements: ${p.data['element_count']}',
      if (partial) 'Partial snapshot returned',
    ],
  );
  if (p.data['snapshot'] == '') p.metadata.add('No page content returned');
  for (final dialog in _maps(p.data['pending_dialogs'])) {
    p.addResponse(
      'Pending ${_text(dialog['type']) ?? 'dialog'}',
      dialog['message'],
      facts: [
        if (_text(dialog['default_prompt']) case final prompt?)
          'Default: $prompt',
      ],
    );
  }
  for (final dialog in _maps(p.data['recent_dialogs'])) {
    final closedBy = switch (dialog['closed_by']) {
      'agent' => 'Closed by the agent',
      'auto_policy' => 'Closed automatically',
      'remote' => 'Closed by a remote client',
      'watchdog' => 'Closed by the watchdog',
      _ => null,
    };
    p.addResponse(
      'Recent ${_text(dialog['type']) ?? 'dialog'}',
      dialog['message'],
      secondary: true,
      facts: [?closedBy],
    );
  }
  if (p.data['frame_tree'] case final Map frames) {
    if (frames['truncated'] == true) p.metadata.add('Frame inventory partial');
  }
  _browserWarnings(p);
}

void _browserNavigate(_ToolProjection p) {
  p.intent = _text(p.args['url']);
  _browserResource(p);
  _browserSnapshotPayload(p);
  final requested = _text(p.args['url']) ?? _text(p.data['requested_url']);
  if (requested != null && requested != p.resourceTarget) {
    p.fact('Requested', requested);
  }
}

void _browserSnapshot(_ToolProjection p) {
  p.fact('Full tree requested', p.args['full']);
  // A snapshot supplies no implicit page URL; never borrow a previous call.
  _browserSnapshotPayload(p);
}

void _browserClick(_ToolProjection p) {
  final ref = _text(p.args['ref']);
  p.intent = ref == null ? null : 'Click $ref';
  p.fact('Target', ref);
  final clicked = _text(p.data['clicked']);
  if (clicked != null) p.addResponse('Result', 'Clicked $clicked');
  _browserResource(p);
  _browserWarnings(p);
}

void _browserType(_ToolProjection p) {
  final ref = _text(p.args['ref']);
  final requested = p.args['text'];
  p.intent = requested == ''
      ? 'Clear field${ref == null ? '' : ' $ref'}'
      : 'Enter text${ref == null ? '' : ' in $ref'}';
  p.fact('Target', ref);
  if (requested == '') {
    p.addRequest('Request', 'Clear the field.');
  } else {
    p.addRequest(
      'Text',
      requested,
      format: ToolDetailFormat.source,
      copyable: true,
    );
  }
  final typed = p.data['typed'];
  if (typed is String && typed != requested && typed.isNotEmpty) {
    p.addResponse(
      'Returned text',
      typed,
      format: ToolDetailFormat.source,
      copyable: true,
    );
  }
  final element = _text(p.data['element']);
  if (typed is String && p.data['success'] == true) {
    p.addResponse(
      'Result',
      typed.isEmpty
          ? 'Cleared${element == null ? ' the field' : ' $element'}.'
          : 'Entered text${element == null ? '' : ' in $element'}.',
    );
  }
  _browserResource(p);
  _browserWarnings(p);
}

void _webSearch(_ToolProjection p) {
  p.intent = _text(p.args['query']);
  p.addRequest(
    'Query',
    p.args['query'],
    role: ToolDetailRole.search,
    copyable: true,
  );
  p.options(p.args, const {'limit': 'Limit'});
  if (p.data['data'] case final Map data) {
    for (final source in _maps(data['web'])) {
      _webSource(p, source, description: true);
    }
    p.warning(data['backend_error']);
    if (data['web'] is List && (data['web'] as List).isEmpty) {
      p.metadata.add('No sources returned');
    }
  }
  for (final key in const ['warning', 'fallback_warning']) {
    p.warning(p.data[key]);
  }
}

void _webExtract(_ToolProjection p) {
  if (p.args['urls'] case final List urls) {
    p.intent = urls.whereType<String>().join(' · ');
  }
  p.options(p.args, const {'char_limit': 'Character limit'});
  final sources = _maps(p.data['results']);
  for (final source in sources) {
    _webSource(p, source);
  }
  if (sources.isNotEmpty &&
      sources.every((source) => _text(source['error']) != null)) {
    p.state = ToolReceiptState.error;
    p.status = 'Could not extract sources';
  }
  if (p.data['results'] is List && (p.data['results'] as List).isEmpty) {
    p.metadata.add('No page content returned');
  }
  p.warning(p.data['warning']);
}

void _webSource(_ToolProjection p, Map source, {bool description = false}) {
  final url = _text(source['url']);
  final link = _web(url);
  final title = _text(source['title']) ?? link?.host ?? 'Source';
  final error = _text(source['error']);
  final excerpt = description ? _text(source['description']) : null;
  final content = description
      ? excerpt ?? _text(source['content']) ?? _text(source['markdown'])
      : _text(source['content']);
  final markdown =
      !description ||
      (excerpt == null &&
          _text(source['content']) == null &&
          _text(source['markdown']) != null);
  final is404 =
      source['status_code'] == 404 ||
      RegExp(
        r'^404(?:\s+error|\s+page\s+not\s+found|\s+not\s+found)?$',
        caseSensitive: false,
      ).hasMatch(title) ||
      RegExp(
        r'^\s*(?:#{1,6}\s*)?404\s+(?:page\s+)?not\s+found\s*$',
        caseSensitive: false,
        multiLine: true,
      ).hasMatch(content ?? '');
  final partial =
      content != null &&
      RegExp(
        r'^──────── \[TRUNCATED\] ────────$',
        multiLine: true,
      ).hasMatch(content);
  // Identity-only sources still offer their actual supported resource; no fake
  // excerpt and no body/resource duplicate copy controls.
  p.response.add(
    ToolDetailBlock(
      label: title,
      text: error ?? content ?? '',
      link: link,
      markdown: markdown && error == null,
      copyable: error == null && content != null,
      role: error == null ? ToolDetailRole.text : ToolDetailRole.warning,
      facts: [
        if (error != null) 'Could not extract this source',
        if (is404) 'Returned a 404 page',
        if (partial) 'Partial page returned',
      ],
    ),
  );
  if (error != null || is404) {
    p.state = ToolReceiptState.warning;
    p.status = error != null
        ? 'Some sources unavailable'
        : 'Returned a 404 page';
  }
}

void _desktopPreview(_ToolProjection p) {
  final action = _text(p.args['action']);
  final target = _text(p.args['url']);
  p.intent = [
    switch (action) {
      'open' => 'Open preview',
      'close' => 'Close preview',
      'read' => 'Read preview',
      _ => 'Preview',
    },
    ?target,
  ].join(' · ');
  if (action == 'read') {
    p.options(p.args, const {'start': 'Start', 'count': 'Count'});
    _browserResource(p, preferPath: true);
    final start = p.data['start'];
    final end = p.data['end'];
    final total = p.data['total_chars'];
    final range = start is num && end is num && total is num
        ? 'Characters $start–$end of $total'
        : null;
    final partial =
        start is num &&
        end is num &&
        total is num &&
        (start > 0 || end < total);
    final text = _text(p.data['text']);
    p.addResponse(
      'Page content',
      text,
      copyable: true,
      facts: [?range, if (partial) 'Partial preview returned'],
    );
    if (text == null && range != null) p.metadata.add(range);
    if (p.data['text'] == '') p.metadata.add('No content returned');
    p.addResponse('Context', p.data['note'], secondary: true);
  } else if (action == 'open') {
    p.resourceTarget = _text(p.data['url']);
    p.fact('Preview', _text(p.data['label']) ?? _text(p.args['label']));
    if (p.data['success'] == true) {
      p.addResponse('Result', 'Preview open request accepted.');
    }
  } else if (action == 'close') {
    final closed = _text(p.data['closed']);
    if (closed != null) {
      p.addResponse(
        'Result',
        closed == 'all'
            ? 'Close request accepted for all previews.'
            : 'Close request accepted for $closed.',
      );
    }
    // A closed target is an acknowledgement, not a resource to open again.
  }
  if (p.output is String) p.addResponse('Result', p.output, copyable: true);
  p.warning(p.data['warning']);
}

void _drivePreview(_ToolProjection p) {
  final action = _text(p.args['action']);
  final target = _text(p.args['ref']) ?? _text(p.args['selector']);
  p.intent = _driveIntent(p.args, action, target);
  if (target != null) p.fact('Target', target);
  p.options(p.args, const {
    'max': 'Limit',
    'full': 'Full inventory requested',
    'allow_shortcut': 'Page shortcut allowed',
  });
  if (action == 'type') {
    if (p.args['text'] == '') {
      p.addRequest('Request', 'Clear the field.');
    } else {
      p.addRequest(
        'Text',
        p.args['text'],
        format: ToolDetailFormat.source,
        copyable: true,
      );
    }
  }
  _browserResource(p);
  p.addResponse('Result', p.data['acted']);
  if (p.data['elements'] case final List elements) {
    p.addResponse(
      'Elements',
      _maps(
        elements,
      ).map(_elementText).where((row) => row.isNotEmpty).join('\n'),
      format: ToolDetailFormat.source,
      role: ToolDetailRole.output,
    );
    if (elements.isEmpty) p.metadata.add('No elements returned');
  }
  if (p.data['delta'] case final Map delta) {
    for (final key in const ['added', 'changed']) {
      p.addResponse(
        key == 'added' ? 'Added elements' : 'Changed elements',
        _maps(
          delta[key],
        ).map(_elementText).where((row) => row.isNotEmpty).join('\n'),
        format: ToolDetailFormat.source,
        role: ToolDetailRole.output,
      );
    }
    if (delta['removed'] case final List removed when removed.isNotEmpty) {
      p.fact('Removed references', removed, result: true);
    }
    if (delta['same'] is num) {
      p.fact('Unchanged surveyed elements', delta['same'], result: true);
    }
  }
  p.addResponse('Context', p.data['note'], secondary: true);
  if (p.data['probably_navigating'] == true && _text(p.data['note']) == null) {
    p.warning('The page may still be navigating.');
  }
  p.warning(p.data['warning']);
}

String? _driveIntent(Map args, String? action, String? target) {
  final operation = switch (action) {
    'type' => args['text'] == '' ? 'Clear field' : 'Enter text',
    'press' => 'Press${_text(args['key']) == null ? '' : ' ${args['key']}'}',
    'scroll' =>
      _text(args['to']) != null
          ? 'Scroll to ${args['to']}'
          : args['amount'] is num
          ? 'Scroll ${args['amount']} px'
          : 'Scroll',
    'elements' => 'Read page controls',
    'click' => 'Click',
    'hover' => 'Hover',
    'back' => 'Go back',
    'forward' => 'Go forward',
    'reload' => 'Reload page',
    'strobe' => 'Strobe field',
    _ => action,
  };
  if (operation == null) return null;
  return [
    operation,
    ?target,
    if (action == 'type' && args['submit'] == true) 'and submit',
  ].join(' ');
}

String _elementText(Map item) => [
  if (_text(item['ref']) case final ref?) '[$ref]',
  ?_text(item['role']),
  ?_text(item['label']),
  if (item.containsKey('value'))
    item['value'] == ''
        ? 'value: (cleared)'
        : 'value: ${_display(item['value'])}',
  if (item['disabled'] == true) '(unavailable)',
  if (item['disabled'] == false) '(available)',
  if (item.containsKey('checked')) 'checked: ${item['checked']}',
].join(' ');
