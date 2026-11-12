part of '../tool_activity_details.dart';

void _terminal(_ToolProjection p) {
  p.addRequest(
    'Command',
    p.args['command'] ?? p.data['command'],
    format: ToolDetailFormat.source,
    role: ToolDetailRole.command,
    language: 'bash',
    copyable: true,
  );
  p.options(p.args, {'workdir': 'Directory', 'timeout': 'Timeout'});
  for (final key in [
    'background',
    'pty',
    'notify',
    'heartbeat',
    'persist_on_release',
  ]) {
    if (p.args[key] != null && p.args[key] != false && p.args[key] != 0) {
      p.fact(key.replaceAll('_', ' '), p.args[key]);
    }
  }
  final background =
      p.data['session_id'] != null &&
      (p.args['background'] == true ||
          p.data['status'] == 'yielded_to_background' ||
          p.data['output'] == 'Background process started');
  if (background) {
    p.state = ToolReceiptState.completed;
    p.status = p.data['status'] == 'yielded_to_background'
        ? 'Continuing in background'
        : 'Started in background';
    p.fact('Process', p.data['session_id'], result: true);
    if (p.data['heartbeat_seconds'] != null) {
      p.fact(
        'Notification interval (seconds)',
        p.data['heartbeat_seconds'],
        result: true,
      );
    }
    if (p.data['watch_patterns'] is List &&
        (p.data['watch_patterns'] as List).isNotEmpty) {
      p.fact('Readiness patterns', p.data['watch_patterns'], result: true);
    }
    if (p.data['notify_on_complete'] == true) {
      p.metadata.add('Completion notification armed');
    }
    if (p.data['persist_on_release'] == true &&
        p.args['persist_on_release'] != true) {
      p.metadata.add('Retained after agent release');
    }
  } else if (p.data['approval_pending'] == true ||
      p.data['status'] == 'pending_approval') {
    p.state = ToolReceiptState.warning;
    p.status = 'Awaiting approval';
    p.addResponse('Approval', p.data['description'], secondary: true);
  } else if (p.data['exit_code'] case final num code) {
    p.exitCode = code;
    if (code != 0) {
      final meaning = _text(p.data['exit_code_meaning']);
      final informational = meaning?.contains('not an error') == true;
      final signal = meaning?.contains('terminated') == true;
      p.state = informational
          ? ToolReceiptState.completed
          : meaning == null || signal
          ? ToolReceiptState.error
          : ToolReceiptState.warning;
      p.status = informational ? 'Completed' : 'Exited with code $code';
      p.addResponse('Exit context', meaning, secondary: true);
    }
  }
  final console = _text(p.data['output']);
  if (console != null && console != 'Background process started') {
    p.addResponse(
      'Output',
      console,
      format: ToolDetailFormat.source,
      role: ToolDetailRole.output,
      copyable: true,
      target: _text(p.data['full_output_path']),
    );
  } else if (p.data.containsKey('output') &&
      !background &&
      p.data['approval_pending'] != true &&
      p.data['status'] != 'pending_approval' &&
      _text(p.data['error']) == null) {
    p.metadata.add('No output returned');
  }
  p.fact('Directory changed to', p.data['cwd'], result: true);
  for (final key in [
    'truncation_note',
    'environment_recreated',
    'retry_hint',
    'notify_unsupported',
    'subagent_note',
    'heartbeat_ignored',
    'watch_patterns_ignored',
    'pty_note',
  ]) {
    p.warning(p.data[key]);
  }
  if (p.data['status'] == 'degraded' || p.data['status'] == 'blocked') {
    p.state = ToolReceiptState.error;
    p.status = p.data['status'] == 'blocked'
        ? 'Blocked'
        : 'Environment unavailable';
    p.addResponse(
      'Context',
      p.data['user_summary'] ?? p.data['reason'],
      secondary: true,
    );
  }
  if (background) p.addResponse('Context', p.data['note'], secondary: true);
  if (p.data['verification_evidence'] case final Map evidence) {
    p.fact('Reported check', evidence['status'], result: true);
    p.fact('Check kind', evidence['kind'], result: true);
    p.fact('Check scope', evidence['scope'], result: true);
    if (evidence['status'] == 'failed') p.warning('The reported check failed.');
  }
  if (_text(p.data['hint']) case final hint?) {
    p.addResponse('Context', hint, secondary: true);
  }
  _executionPlainReceipt(p);
}

void _executeCode(_ToolProjection p) {
  p.addRequest(
    'Code',
    p.args['code'],
    format: ToolDetailFormat.source,
    role: ToolDetailRole.code,
    language: 'python',
    copyable: true,
  );
  if (p.args['reset'] == true) p.headerFacts.add('Reset requested');
  _codeReceipt(p, p.data);
  for (final error in _maps(p.data['tool_errors'])) {
    p.warning(
      _text(error['error']),
      label: _text(error['tool']) ?? 'Reported tool error',
    );
  }
  if (p.data['kernel'] case final Map kernel) {
    if (kernel['state_lost'] == true) {
      p.warning(_text(kernel['note']) ?? 'The kernel reported lost state.');
    }
    if (kernel['ended'] == true) p.metadata.add('Kernel ended');
    if (kernel['state_reset'] == true) p.metadata.add('Kernel state reset');
  }
  _executionPlainReceipt(p);
}

void _codeReceipt(_ToolProjection p, Map data) {
  if (data['exit_code'] case final num code) p.exitCode = code;
  p.addResponse(
    'Output',
    data['output'],
    format: ToolDetailFormat.source,
    role: ToolDetailRole.output,
    copyable: true,
    target: _text(data['stdout_spill_path']),
  );
  if (data['output'] == '' && _text(data['error']) == null) {
    p.metadata.add('No output returned');
  }
  if (const ['error', 'timeout', 'interrupted'].contains(data['status']) ||
      (data['exit_code'] is num && data['exit_code'] != 0) ||
      data['success'] == false) {
    p.state = ToolReceiptState.error;
    p.status = switch (data['status']) {
      'timeout' => 'Timed out',
      'interrupted' => 'Interrupted',
      _ => 'Failed',
    };
  }
  if (data['stdout_truncated'] == true) {
    p.metadata.add('Partial output returned');
    p.fact(
      'Captured stdout bytes',
      data['stdout_bytes_captured'],
      result: true,
    );
    p.fact('Omitted stdout bytes', data['stdout_bytes_omitted'], result: true);
  }
  p.warning(data['warning']);
  p.addResponse(
    'Context',
    data['hint'] ?? data['user_summary'],
    secondary: true,
  );
}

void _browserExec(_ToolProjection p) {
  p.addRequest(
    'Code',
    p.args['code'],
    format: ToolDetailFormat.source,
    role: ToolDetailRole.code,
    language: 'python',
    copyable: true,
  );
  p.options(p.args, {'session': 'Session', 'timeout_s': 'Timeout'});
  if (p.args['local'] == true) p.headerFacts.add('Local browser requested');
  final receipt = _browserExecutionReceipt(p.output) ?? p.data;
  _codeReceipt(p, receipt);
  p.addResponse(
    'Diagnostics',
    receipt['stderr'],
    format: ToolDetailFormat.source,
    role: ToolDetailRole.output,
    copyable: true,
  );
  if (_text(receipt['error']) case final error?) {
    p.addResponse('Error', error, role: ToolDetailRole.warning);
    p.state = ToolReceiptState.error;
    p.status = 'Failed';
  }
  final nativeMeta = p.data['meta'];
  final screenshot =
      _text(receipt['screenshot_path']) ??
      (nativeMeta is Map ? _text(nativeMeta['screenshot_path']) : null);
  p.image('Screenshot', screenshot ?? _nativeImage(p.output));
  p.fact('Workspace', receipt['workspace'], result: true);
  if (p.args['session'] == null) {
    p.fact('Session', receipt['session'], result: true);
  }
  p.addResponse('Result', receipt['message']);
  _executionPlainReceipt(p);
}

Map? _browserExecutionReceipt(Object? output) {
  final candidates = <String>[];
  if (output is Map &&
      output['_multimodal'] == true &&
      output['text_summary'] is String) {
    candidates.add(output['text_summary'] as String);
  }
  final parts = output is Map ? output['content'] : output;
  for (final part in _maps(parts)) {
    final text = part['type'] == 'text' ? _text(part['text']) : null;
    if (text != null) {
      candidates.add(
        text.split('\n\nThe screenshot from this call is attached').first,
      );
    }
  }
  for (final text in candidates) {
    try {
      final parsed = jsonDecode(text);
      if (parsed is Map) return parsed;
    } on FormatException {
      // The exact envelope remains available in Raw details.
    }
  }
  return null;
}

String? _nativeImage(Object? output) {
  final parts = output is Map ? output['content'] : output;
  for (final part in _maps(parts)) {
    if (part['type'] == 'image_url' && part['image_url'] is Map) {
      final target = _text((part['image_url'] as Map)['url']);
      if (target != null) return target;
    }
  }
  return null;
}

void _imageGenerate(_ToolProjection p) {
  p.addRequest('Prompt', p.args['prompt'], markdown: true, copyable: true);
  p.options(p.args, {
    'aspect_ratio': 'Aspect ratio',
    'upscale': 'Upscale',
    'creativity': 'Creativity',
    'intensity': 'Intensity',
    'complexity': 'Complexity',
    'movement': 'Movement',
  });
  p.image('Source image', p.args['image_url']);
  if (p.args['reference_image_urls'] case final List refs) {
    for (var i = 0; i < refs.length; i++) {
      p.image('Reference ${i + 1}', refs[i]);
    }
  }
  p.image(
    'Generated image',
    _text(p.data['image']) ?? _text(p.data['public_url']),
  );
  if (p.data['additional_images'] case final List images) {
    for (var i = 0; i < images.length; i++) {
      p.image('Generated image ${i + 2}', images[i]);
    }
  }
  if (p.data['prompt'] != p.args['prompt']) {
    p.addResponse(
      p.args['prompt'] == null ? 'Prompt' : 'Reported prompt',
      p.data['prompt'],
      markdown: true,
      copyable: true,
    );
  }
  if (p.data['revised_prompt'] != p.args['prompt']) {
    p.addResponse(
      'Revised prompt',
      p.data['revised_prompt'],
      markdown: true,
      copyable: true,
    );
  }
  p.fact('Provider', p.data['provider'], result: true);
  p.fact('Model', p.data['model'], result: true);
  p.fact('Pixels', p.data['pixel_size'], result: true);
  p.fact('Image size setting', p.data['size'], result: true);
  for (final entry in {
    'quality': 'Quality',
    'resolution': 'Resolution',
    'exact_aspect_ratio': 'Exact aspect ratio',
    'cost_usd': 'Reported cost (USD)',
    'seed': 'Seed',
  }.entries) {
    p.fact(entry.value, p.data[entry.key], result: true);
  }
  if (p.data['aspect_ratio'] != p.args['aspect_ratio']) {
    p.fact('Reported aspect ratio', p.data['aspect_ratio'], result: true);
  }
  if (p.data['reported_size'] != p.data['requested_size']) {
    p.fact('Requested size', p.data['requested_size'], result: true);
    p.fact('Provider reported size', p.data['reported_size'], result: true);
  }
  if (p.data['reported_quality'] != p.data['quality']) {
    p.fact(
      'Provider reported quality',
      p.data['reported_quality'],
      result: true,
    );
  }
  final sourceCount =
      (p.args['image_url'] is String ? 1 : 0) +
      (p.args['reference_image_urls'] is List
          ? (p.args['reference_image_urls'] as List).length
          : 0);
  if (p.data['input_image_count'] is num &&
      p.data['input_image_count'] != sourceCount) {
    p.fact('Input images used', p.data['input_image_count'], result: true);
  }
  if (p.data['reference_images_used'] is num) {
    p.fact(
      'Reference images used',
      p.data['reference_images_used'],
      result: true,
    );
  }
  p.fact(
    'Public image expiry',
    p.data['public_url_expires_at'] ?? p.data['expires_at'],
    result: true,
  );
  if (p.data['upscaled'] == true) {
    p.fact('Upscaled', p.data['upscale_factor'] ?? true, result: true);
  }
  if (p.args['upscale'] == true && p.data['upscaled'] == false) {
    p.metadata.add('Upscaling was not reported');
  }
  if (p.data['success'] == true &&
      _text(p.data['image']) == null &&
      _text(p.data['public_url']) == null) {
    p.metadata.add('No image returned');
  }
  if (p.data['notes'] case final List notes) {
    for (final note in notes) {
      p.warning(note);
    }
  }
  for (final key in ['storage_notice', 'storage_error', 'public_url_error']) {
    p.warning(p.data[key]);
  }
  _executionPlainReceipt(p);
}

void _visionAnalyze(_ToolProjection p) {
  p.addRequest(
    'Question',
    p.args['question'],
    role: ToolDetailRole.question,
    markdown: true,
    copyable: true,
  );
  p.fact('Requested region', p.args['region']);
  final embedded = _nativeImage(p.output);
  final source = _text(p.args['image_url']);
  final parts = _maps(p.data['content'] ?? p.output);
  final nativeText = parts
      .where((part) => part['type'] == 'text')
      .map((part) => _text(part['text']))
      .whereType<String>()
      .toList();
  final literalReceipt =
      p.output is String &&
      (p.output as String).startsWith(
        'Image attached natively for the main model',
      );
  final nativeMarker =
      p.data['_multimodal'] == true ||
      (p.data['meta'] is Map &&
          (p.data['meta'] as Map)['native_vision'] == true) ||
      nativeText.any(
        (text) => text.startsWith('Image loaded into your context'),
      );
  p.nativeVision = nativeMarker || literalReceipt || embedded != null;
  // Only actual received pixels establish a crop representation. The source remains a source.
  p.image(
    embedded != null
        ? 'Received image'
        : source != null
        ? 'Source image'
        : 'Image',
    embedded ?? source,
  );
  if (p.data['already_in_context'] == true) {
    p.metadata.add('Already attached for the agent');
  } else if (p.nativeVision &&
      _text(p.data['error']) == null &&
      p.data['success'] != false) {
    // The native receipt remains quiet context under ordinary Completed.
    for (final text in nativeText) {
      final noteAt = text.indexOf('\n\nNote: ');
      if (noteAt >= 0) {
        p.addResponse(
          'Image context',
          text.substring(noteAt + 8),
          secondary: true,
        );
      }
      if (_text(p.args['question']) == null) {
        final questionAt = text.indexOf('\n\nQuestion: ');
        if (questionAt >= 0) {
          final end = noteAt > questionAt ? noteAt : text.length;
          p.addResponse(
            'Received question',
            text.substring(questionAt + 12, end),
            role: ToolDetailRole.question,
            markdown: true,
            copyable: true,
          );
        }
      }
    }
  } else {
    final analysis = _text(p.data['analysis']);
    final scale = _text(p.data['scale_note']);
    if (analysis != null) {
      final display = scale != null && analysis.startsWith('[$scale]')
          ? analysis.substring(scale.length + 2).trimLeft()
          : analysis;
      final emptyReceipt =
          display ==
          'There was a problem with the request and the image could not be analyzed.';
      final failed =
          p.data['success'] == false || _text(p.data['error']) != null;
      p.addResponse(
        failed
            ? 'Context'
            : emptyReceipt
            ? 'Result'
            : 'Analysis',
        display,
        markdown: !failed,
        copyable: !failed && !emptyReceipt,
        exactCopyText: analysis,
      );
      if (emptyReceipt) {
        p.state = ToolReceiptState.warning;
        p.status = 'No analysis returned';
      }
    }
    if (scale != null) p.addResponse('Image context', scale, secondary: true);
  }
  if (!p.nativeVision) _executionPlainReceipt(p);
}

void _executionPlainReceipt(_ToolProjection p) {
  if (p.output is String && p.response.isEmpty) {
    p.addResponse('Result', p.output);
  }
}
