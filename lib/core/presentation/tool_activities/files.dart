part of '../tool_activity_details.dart';

bool _fileReceiptFailed(_ToolProjection p) =>
    _text(p.data['error']) != null || p.data['success'] == false;

String? _fileDestination(_ToolProjection p) =>
    _text(p.data['resolved_path']) ?? _text(p.args['path']);

bool _fileTarget(String? path) =>
    path != null && !path.endsWith('/') && !path.endsWith(r'\');

void _fileWarnings(_ToolProjection p) {
  p.warning(p.data['warning']);
  p.warning(p.data['_warning']);
}

void _readFile(_ToolProjection p) {
  p.layout = ToolActivityLayout.file;
  p.intent = _text(p.args['path']) ?? _text(p.data['path']);
  p.options(p.args, const {'offset': 'Offset', 'limit': 'Limit'});
  final failed = _fileReceiptFailed(p);
  final binary = p.data['is_binary'] == true;
  final target = _fileDestination(p) ?? _text(p.data['path']);
  if (!failed && !binary && _fileTarget(target)) p.resourceTarget = target;

  if (p.data['status'] == 'unchanged') {
    p.metadata.add('Unchanged; no content returned');
    p.status = 'Unchanged';
    p.addResponse('Result', p.data['message'], secondary: true);
  } else if (p.data['content'] case final String content
      when !failed || content.isNotEmpty) {
    final markdown = RegExp(
      r'\.(md|markdown)$',
      caseSensitive: false,
    ).hasMatch(target ?? '');
    p.response.add(
      ToolDetailBlock(
        label: 'Result',
        text: content,
        showEmpty: content.isEmpty,
        format: ToolDetailFormat.source,
        role: ToolDetailRole.output,
        numberedLines: true,
        language: binary || p.data['extracted_document'] == true
            ? null
            : sourceLanguageForPath(target),
        markdown: markdown,
        copyable: content.isNotEmpty,
      ),
    );
  }
  if (!failed) {
    if (p.data['total_lines'] case final num lines
        when lines.isFinite && lines >= 0) {
      p.fact('Total lines', lines, result: true);
    }
    if (p.data['extracted_document'] == true) p.metadata.add('Extracted text');
  }
  if (p.data['truncated'] == true) p.metadata.add('Partial file returned');
  if (p.data['truncated_lines'] == true) {
    p.warning('The backend clipped one or more returned lines.');
  }
  if (p.data['truncated_by'] == 'bytes') {
    p.metadata.add('Read character budget reached');
  }
  if (p.data['next_offset'] case final num offset
      when offset.isFinite && offset > 0) {
    p.fact('Next offset', offset, result: true);
  }
  if (p.data['conflict_blocks'] case final num count
      when count.isFinite && count > 0) {
    p.warning('$count unresolved merge-conflict blocks in the returned range.');
  }
  p.addResponse('Context', p.data['hint'], secondary: true);
  p.addResponse('Recovery', p.data['_hint'], secondary: true);
  if (p.data['success'] == false && p.data['note'] is String) {
    p.addResponse('Result', p.data['note'], role: ToolDetailRole.warning);
    p.status = 'Read not attempted';
  }
  if (p.data['similar_files'] case final List paths) {
    final candidates = paths.whereType<String>().where(
      (s) => s.trim().isNotEmpty,
    );
    for (final path in candidates) {
      p.response.add(
        ToolDetailBlock(label: 'Similar file', text: '', facts: [path]),
      );
    }
  }
  if (p.resourceTarget == null &&
      p.intent != null &&
      p.layout == ToolActivityLayout.file) {
    p.fact('File', p.intent);
  }
  _fileWarnings(p);
}

void _writeFile(_ToolProjection p) {
  p.layout = ToolActivityLayout.file;
  p.intent = _text(p.args['path']);
  final target = _fileDestination(p);
  // A requested destination alone is not a written resource. Stock WriteResult
  // supplies bytes_written even for an empty file; errors still prohibit actions.
  if (p.data['bytes_written'] case final int bytes
      when bytes >= 0 && !_fileReceiptFailed(p) && _fileTarget(target)) {
    p.resourceTarget = target;
  }
  final content = p.args['content'];
  p.addRequest(
    'Content to write',
    content,
    format: ToolDetailFormat.source,
    role: ToolDetailRole.code,
    language: sourceLanguageForPath(_text(p.args['path'])),
    copyable: content is String && content.isNotEmpty,
  );
  if (p.data['verified'] == true && !_fileReceiptFailed(p)) {
    p.metadata.add('Content hash verified');
  }
  // Missing verification is unknown; neither a hash result nor broad correctness
  // is reconstructed from bytes_written or the requested source.
  if (p.data['bytes_written'] == 0 && !_fileReceiptFailed(p)) {
    p.metadata.add('Wrote an empty file');
  }
  _fileDiagnostics(p);
  if (p.resourceTarget == null &&
      p.intent != null &&
      p.layout == ToolActivityLayout.file) {
    p.fact('File', p.intent);
  }
  _fileWarnings(p);
}

void _patchFile(_ToolProjection p) {
  p.intent = _text(p.args['path']);
  p.options(p.args, const {'mode': 'Mode', 'replace_all': 'Replace all'});
  final requestedPatch = p.args['patch'];
  if (p.args['mode'] == 'patch') {
    p.addRequest(
      'Requested patch',
      requestedPatch,
      format: ToolDetailFormat.diff,
      role: ToolDetailRole.diff,
      copyable: requestedPatch is String && requestedPatch.isNotEmpty,
    );
  } else {
    for (final entry in const {
      'old_string': 'Find',
      'new_string': 'Replace with',
    }.entries) {
      final value = p.args[entry.key];
      p.addRequest(
        entry.value,
        value,
        format: ToolDetailFormat.source,
        role: ToolDetailRole.code,
        language: sourceLanguageForPath(_text(p.args['path'])),
        copyable: value is String && value.isNotEmpty,
      );
    }
  }
  final noChange = p.data['no_change'] == true;
  if (noChange && !_fileReceiptFailed(p)) {
    p.state = ToolReceiptState.completed;
    p.status = 'No change';
    p.addResponse('Result', p.data['note'], secondary: true);
  } else {
    p.addResponse(
      'Reported diff',
      p.data['diff'],
      format: ToolDetailFormat.diff,
      role: ToolDetailRole.diff,
      copyable: true,
    );
  }
  final deleted = p.data['files_deleted'] is List
      ? (p.data['files_deleted'] as List).whereType<String>().toSet()
      : <String>{};
  final target = _fileDestination(p);
  if (p.data['success'] == true &&
      !_fileReceiptFailed(p) &&
      !noChange &&
      !deleted.contains(target) &&
      _fileTarget(target)) {
    p.resourceTarget = target;
  }
  // Stock's wrapper reports requested paths in files_modified, even on a no-op.
  // Keep that bookkeeping Raw unless an actual returned effect is available.
  if (!noChange) {
    for (final entry in const {
      'files_created': 'Created',
      'files_deleted': 'Deleted',
    }.entries) {
      if (p.data[entry.key] case final List paths) {
        for (final path in paths.whereType<String>()) {
          p.response.add(
            ToolDetailBlock(
              label: entry.value,
              text: '',
              facts: [path],
              resourceTarget:
                  entry.key == 'files_created' &&
                      !deleted.contains(path) &&
                      _fileTarget(path)
                  ? path
                  : null,
            ),
          );
        }
      }
    }
  }
  p.addResponse('Recovery', p.data['_hint'], secondary: true);
  _fileDiagnostics(p);
  if (p.resourceTarget == null && p.intent != null) {
    p.fact('File', p.intent);
  }
  _fileWarnings(p);
}

void _fileDiagnostics(_ToolProjection p) {
  final lint = p.data['lint'];
  if (lint is Map) {
    if (lint['status'] is String) {
      _fileSyntaxDiagnostic(p, lint);
    } else {
      for (final entry in lint.entries) {
        if (entry.key is String && entry.value is Map) {
          _fileSyntaxDiagnostic(
            p,
            entry.value as Map,
            path: entry.key as String,
          );
        }
      }
    }
  }
  if (_text(p.data['lsp_diagnostics']) != null &&
      p.state != ToolReceiptState.error) {
    p.state = ToolReceiptState.warning;
    p.status ??= 'Completed with a warning';
  }
  p.addResponse(
    'Semantic diagnostics',
    p.data['lsp_diagnostics'],
    format: ToolDetailFormat.source,
    role: ToolDetailRole.warning,
  );
}

void _fileSyntaxDiagnostic(_ToolProjection p, Map lint, {String? path}) {
  if (lint['status'] != 'error') return;
  p.warning(
    path == null ? 'Syntax check failed.' : 'Syntax check failed for $path.',
  );
  p.addResponse(
    'Syntax diagnostics',
    lint['output'],
    format: ToolDetailFormat.source,
    role: ToolDetailRole.warning,
    facts: [?path],
  );
  p.addResponse(
    'Syntax context',
    lint['message'],
    role: ToolDetailRole.warning,
    secondary: true,
    facts: [?path],
  );
}

const _stockDenseMatchFormat =
    "path-grouped: each file path on its own line, followed by indented '<line>: <content>' rows for matches in that file";

void _searchFiles(_ToolProjection p) {
  p.layout = ToolActivityLayout.search;
  p.intent = [
    _text(p.args['pattern']),
    _text(p.args['path']),
  ].whereType<String>().join(' · ');
  final pattern = p.args['pattern'];
  p.addRequest(
    'Pattern',
    pattern,
    format: ToolDetailFormat.source,
    role: ToolDetailRole.search,
    copyable: pattern is String && pattern.isNotEmpty,
  );
  p.options(p.args, const {
    'target': 'Target',
    'limit': 'Limit',
    'offset': 'Offset',
  });
  final fileSearch = p.args['target'] == 'files';
  p.options(
    p.args,
    fileSearch
        ? const {'order': 'Order'}
        : const {
            'file_glob': 'Files',
            'output_mode': 'Output',
            'context': 'Context',
          },
  );
  final count = p.data['total_count'];
  if (count is num && count.isFinite && count >= 0 && !_fileReceiptFailed(p)) {
    final kind = fileSearch || p.args['output_mode'] == 'files_only'
        ? 'files'
        : p.args['output_mode'] == 'count'
        ? 'matches'
        : 'rows';
    final qualified = p.data['total_count_is_lower_bound'] == true;
    p.metadata.add('Reported $kind: ${qualified ? 'at least ' : ''}$count');
  }
  if (p.data['truncated'] == true) p.metadata.add('Partial results returned');
  if (p.data['limit_reason'] == 'search_timeout') {
    p.warning('Search timed out; returned results may be incomplete.');
  }

  if (p.data['matches'] case final List matches) {
    final groups = <String, List<({int line, String content})>>{};
    var malformed = false;
    for (final match in matches) {
      if (match is Map &&
          match['path'] is String &&
          (match['path'] as String).trim().isNotEmpty &&
          match['line'] is int &&
          (match['line'] as int) > 0 &&
          match['content'] is String) {
        groups.putIfAbsent(match['path'] as String, () => []).add((
          line: match['line'] as int,
          content: match['content'] as String,
        ));
      } else {
        malformed = true;
      }
    }
    for (final entry in groups.entries) {
      _fileSearchGroup(p, entry.key, entry.value);
    }
    if (malformed) {
      p.warning(
        'Some returned search rows could not be displayed; inspect Raw details.',
      );
    }
  } else if (p.data.containsKey('matches_text')) {
    _denseFileSearch(p);
  }
  if (p.data['files'] case final List files) {
    final paths = files
        .whereType<String>()
        .where((path) => path.trim().isNotEmpty)
        .toList();
    if (paths.isNotEmpty) {
      if (!fileSearch && p.args['output_mode'] == 'files_only') {
        for (final path in paths) {
          p.response.add(
            ToolDetailBlock(
              label: 'Matching file',
              text: '',
              facts: [path],
              resourceTarget: _fileTarget(path) ? path : null,
            ),
          );
        }
      } else {
        // Filename discovery also returns directories without a type field.
        // This useful batch is reusable, but does not invent per-path file actions.
        p.addResponse(
          'Files',
          paths.join('\n'),
          format: ToolDetailFormat.source,
          role: ToolDetailRole.search,
          copyable: true,
        );
      }
    }
  }
  if (p.data['counts'] case final Map counts) {
    for (final entry in counts.entries) {
      if (entry.key is String &&
          _text(entry.key) != null &&
          entry.value is num &&
          (entry.value as num).isFinite &&
          (entry.value as num) >= 0) {
        final path = entry.key as String;
        p.response.add(
          ToolDetailBlock(
            label: 'Matches',
            text: '',
            facts: ['Reported matches: ${entry.value}'],
            resourceTarget: _fileTarget(path) ? path : null,
          ),
        );
      }
    }
  }
  p.warning(p.data['_omitted']);
  p.addResponse('Recovery', p.data['_hint'], secondary: true);
  if (p.resourceTarget == null &&
      p.intent != null &&
      p.layout == ToolActivityLayout.file) {
    p.fact('File', p.intent);
  }
  _fileWarnings(p);
}

void _fileSearchGroup(
  _ToolProjection p,
  String path,
  List<({int line, String content})> rows, {
  List<String>? exactRows,
}) {
  // Current stock parses context at the rightmost -<number>- separator, even
  // inside source dates. A sibling of an explicitly searched file/directory
  // cannot be a result inside that scope. Keep its original fields in Raw;
  // neither reconstruct a filename nor offer I/O for the contradictory locator.
  final scope = _text(p.args['path']);
  if ((p.args['context'] is num && (p.args['context'] as num) > 0) &&
      scope != null &&
      path.startsWith('$scope-') &&
      RegExp(r'^-[1-9]\d*-').hasMatch(path.substring(scope.length))) {
    if (!p.response.any((block) => block.label == 'Search context warning')) {
      p.warning(
        'Some context rows have unreliable file locations; inspect Raw details.',
        label: 'Search context warning',
      );
    }
    return;
  }
  final text = rows.map((row) => '${row.line}|${row.content}').join('\n');
  p.response.add(
    ToolDetailBlock(
      label: 'Returned excerpts',
      text: text,
      format: ToolDetailFormat.source,
      role: ToolDetailRole.search,
      copyable: rows.any((row) => row.content.isNotEmpty),
      exactCopyText:
          exactRows?.join('\n') ?? rows.map((row) => row.content).join('\n'),
      resourceTarget: _fileTarget(path) ? path : null,
      facts: [if (!_fileTarget(path)) path],
    ),
  );
}

void _denseFileSearch(_ToolProjection p) {
  final dense = p.data['matches_text'];
  if (p.data['matches_format'] != _stockDenseMatchFormat ||
      dense is! String ||
      dense.isEmpty) {
    p.warning(
      'Returned search excerpts have an unsupported format; inspect Raw details.',
    );
    return;
  }
  final groups =
      <
        ({
          String path,
          List<({int line, String content})> rows,
          List<String> exact,
        })
      >[];
  final rowPattern = RegExp(r'^  ([1-9]\d*): (.*)$');
  var valid = true;
  for (final line in dense.split('\n')) {
    final row = rowPattern.firstMatch(line);
    if (row != null && groups.isNotEmpty) {
      final number = int.tryParse(row.group(1)!);
      if (number == null) {
        valid = false;
        break;
      }
      groups.last.rows.add((line: number, content: row.group(2)!));
      groups.last.exact.add(line);
    } else if (line.trim().isNotEmpty &&
        !line.startsWith('  ') &&
        (groups.isEmpty || groups.last.rows.isNotEmpty)) {
      groups.add((path: line, rows: [], exact: []));
    } else {
      valid = false;
      break;
    }
  }
  if (!valid || groups.isEmpty || groups.last.rows.isEmpty) {
    p.warning(
      'Returned search excerpts could not be grouped; inspect Raw details.',
    );
    return;
  }
  for (final group in groups) {
    _fileSearchGroup(p, group.path, group.rows, exactRows: group.exact);
  }
}
