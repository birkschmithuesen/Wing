import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/gateway_activity.dart';
import 'package:wing/core/presentation/tool_activity_details.dart';
import 'package:wing/core/presentation/tool_call_presentation.dart';
import 'package:wing/core/widgets/tool_activity_details.dart';

ToolActivityDetails project(
  String name,
  Map<String, Object?> args,
  Map<String, Object?> data,
) => ToolActivityDetails.project(name: name, input: args, output: data);

void main() {
  for (final name in ['write_file', 'patch']) {
    testWidgets('$name waits for its receipt before file preview and share', (
      tester,
    ) async {
      const path = '/work/report.txt';
      final args = name == 'write_file'
          ? {'path': path, 'content': 'new bytes'}
          : {'path': path, 'old_string': 'old', 'new_string': 'new'};
      var opened = false;
      var shared = false;
      final call = ToolCallPresentation.live(
        GatewayToolActivity(
          name: name,
          phase: GatewayToolActivityPhase.running,
          arguments: jsonEncode(args),
        ),
      );
      expect(call.outcome, ToolCallOutcome.running);
      expect(call.activityDetails.resourceTarget, isNull);
      expect(call.activityDetails.headerFacts, contains('File: $path'));
      expect(call.activityDetails.request.first.copyable, isTrue);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ToolActivityDetailsView(
                call: call,
                onOpenResource: (_) async {
                  opened = true;
                },
                onShareResource: (_) async {
                  shared = true;
                },
              ),
            ),
          ),
        ),
      );
      expect(find.byTooltip('Preview file'), findsNothing);
      expect(find.byTooltip('Share file'), findsNothing);
      expect(
        find.byTooltip(
          name == 'write_file' ? 'Copy Content to write' : 'Copy Find',
        ),
        findsOneWidget,
      );
      expect(opened, isFalse);
      expect(shared, isFalse);

      final completed = ToolCallPresentation.live(
        GatewayToolActivity(
          name: name,
          phase: GatewayToolActivityPhase.completed,
          arguments: jsonEncode(args),
          result: jsonEncode({
            'resolved_path': '/work/actual.txt',
            if (name == 'write_file') 'bytes_written': 9 else 'success': true,
          }),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ToolActivityDetailsView(
                call: completed,
                onOpenResource: (resource) async {
                  expect(resource.path, '/work/actual.txt');
                  opened = true;
                },
                onShareResource: (resource) async {
                  expect(resource.path, '/work/actual.txt');
                  shared = true;
                },
              ),
            ),
          ),
        ),
      );
      expect(find.byTooltip('Preview file'), findsOneWidget);
      expect(find.byTooltip('Share file'), findsOneWidget);
      await tester.tap(find.byTooltip('Share file'));
      await tester.pump();
      expect(shared, isTrue);
      await tester.tap(find.byTooltip('Preview file'));
      await tester.pump();
      expect(opened, isTrue);
    });

    test(
      '$name empty or bookkeeping-only receipts cannot admit file actions',
      () {
        for (final output in [
          null,
          <String, Object?>{},
          {'resolved_path': '/work/report.txt', '_warning': 'Caution'},
        ]) {
          final detail = ToolActivityDetails.project(
            name: name,
            input: {'path': '/work/report.txt'},
            output: output,
          );
          expect(detail.resourceTarget, isNull);
        }
      },
    );
  }

  test('stock context parsing cannot turn code dates into file resources', () {
    const actualPath = 'tests/test_current_plan.py';
    const corruptedPath =
        "tests/test_current_plan.py-28-self.assertEqual(['2027-10-02', '2027-10-03', '2027-10-04', '2027";
    const format =
        "path-grouped: each file path on its own line, followed by indented '<line>: <content>' rows for matches in that file";
    for (final receipt in [
      {
        'matches': [
          {'path': corruptedPath, 'line': 10, 'content': "05'], actual)"},
          {'path': actualPath, 'line': 29, 'content': 'linked = items'},
        ],
      },
      {
        'matches_format': format,
        'matches_text':
            "$corruptedPath\n  10: 05'], actual)\n$actualPath\n  29: linked = items",
      },
    ]) {
      final detail = project('search_files', {
        'path': actualPath,
        'pattern': 'stay-H03',
        'context': 2,
      }, receipt);
      expect(
        detail.response
            .where((b) => b.resourceTarget != null)
            .map((b) => b.resourceTarget),
        [actualPath],
      );
      expect(
        detail.response.any((b) => b.label == 'Search context warning'),
        isTrue,
      );
      expect(detail.receiptState, ToolReceiptState.warning);
      expect(
        detail.response.any((b) => b.text.contains('linked = items')),
        isTrue,
      );
    }
  });

  test(
    'read Markdown preserves exact receipt and deliberate empty content',
    () {
      const receipt = '21|# Report\n22|\n23|**Ready**';
      final read = project(
        'read_file',
        {'path': '/work/report.md', 'offset': 21, 'limit': 3},
        {
          'content': receipt,
          'total_lines': 80,
          'truncated': true,
          'next_offset': 24,
        },
      );
      final content = read.response.single;
      expect(read.layout, ToolActivityLayout.file);
      expect(read.headerFacts, ['Offset: 21', 'Limit: 3']);
      expect(content.numberedLines, isTrue);
      expect(content.markdown, isTrue);
      expect(content.documentText, '# Report\n\n**Ready**');
      expect(content.copyText, receipt);
      expect(read.resourceTarget, '/work/report.md');
      expect(
        read.metadata,
        containsAll([
          'Total lines: 80',
          'Partial file returned',
          'Next offset: 24',
        ]),
      );
    },
  );

  test('empty file receipt is deliberate and not copyable', () {
    final empty = project(
      'read_file',
      {'path': '/work/empty.txt'},
      {
        'content': '',
        'file_size': 0,
        'total_lines': 0,
        'hint': 'File is empty (0 bytes).',
      },
    );
    expect(empty.response.first.text, '');
    expect(empty.response.first.copyable, isFalse);
    expect(empty.response.last.text, 'File is empty (0 bytes).');
  });

  test(
    'read omissions, no-content stubs and explicit refusals remain distinct',
    () {
      final clipped = project(
        'read_file',
        {'path': '/work/wide.txt'},
        {
          'content': '1|wide... [truncated]',
          'truncated_lines': true,
          'truncated_by': 'bytes',
          'next_offset': 2,
          'conflict_blocks': 1,
          '_hint': 'Resolve the conflict markers before editing.',
        },
      );
      expect(clipped.metadata, contains('Read character budget reached'));
      expect(
        clipped.response.map((b) => b.text),
        contains('Resolve the conflict markers before editing.'),
      );
      expect(
        clipped.response
            .where((b) => b.role == ToolDetailRole.warning)
            .every((b) => !b.copyable),
        isTrue,
      );
    },
  );

  test('unchanged read receipt does not invent returned content', () {
    final unchanged = project(
      'read_file',
      {'path': '/work/file.txt'},
      {
        'status': 'unchanged',
        'content_returned': false,
        'dedup': true,
        'message': 'Reuse the earlier receipt.',
      },
    );
    expect(unchanged.receiptStatus, 'Unchanged');
    expect(unchanged.response.single.copyable, isFalse);
    expect(unchanged.metadata, ['Unchanged; no content returned']);
  });

  test('failed reads and special files have no current-file actions', () {
    final failed = project(
      'read_file',
      {'path': '/work/missing.txt'},
      {
        'content': '',
        'total_lines': 0,
        'file_size': 0,
        'not_found': true,
        'error': 'File not found.',
      },
    );
    expect(failed.resourceTarget, isNull);
    expect(failed.metadata, isEmpty);
    expect(failed.receiptState, ToolReceiptState.error);
  });

  test('special file refusal has no current-file action', () {
    final special = project(
      'read_file',
      {'path': '/work/input.pipe'},
      {'success': false, 'note': 'No read attempted; this is a FIFO.'},
    );
    expect(special.resourceTarget, isNull);
    expect(special.receiptStatus, 'Read not attempted');
    expect(special.response.single.copyable, isFalse);
  });

  test('writes show requested source and only supplied verification', () {
    final written = project(
      'write_file',
      {'path': 'note.md', 'content': '# Requested\n'},
      {
        'bytes_written': 12,
        'verified': true,
        'resolved_path': '/work/note.md',
        'dirs_created': true,
        'lint': {'status': 'skipped', 'message': 'No linter available'},
      },
    );
    expect(written.layout, ToolActivityLayout.file);
    expect(written.resourceTarget, '/work/note.md');
    expect(written.request.single.text, '# Requested\n');
    expect(written.request.single.markdown, isFalse);
    expect(written.request.single.copyable, isTrue);
    expect(written.metadata, ['Content hash verified']);
    expect(written.response, isEmpty);
  });

  test('empty write does not invent verification', () {
    final unknownVerification = project(
      'write_file',
      {'path': '/work/file.txt', 'content': ''},
      {'bytes_written': 0},
    );
    expect(unknownVerification.metadata, ['Wrote an empty file']);
    expect(unknownVerification.resourceTarget, '/work/file.txt');
    expect(unknownVerification.request.single.copyable, isFalse);
  });

  test(
    'refused write retains requested source without a current-file action',
    () {
      final refusal = project(
        'write_file',
        {'path': '/work/file.txt', 'content': 'requested'},
        {
          'bytes_written': 0,
          'stale_write_blocked': true,
          'error': 'The file was NOT modified.',
        },
      );
      expect(refusal.request.single.text, 'requested');
      expect(refusal.resourceTarget, isNull);
      expect(refusal.receiptState, ToolReceiptState.error);
    },
  );

  test('patch successful receipt admits the actual surviving destination', () {
    final changed = project(
      'patch',
      {'path': 'requested.py', 'old_string': 'old', 'new_string': 'new'},
      {
        'success': true,
        'diff': '-old\n+new',
        'resolved_path': '/work/actual.py',
      },
    );
    expect(changed.resourceTarget, '/work/actual.py');
  });

  test('deleted patch destination has no current-file action', () {
    final deleted = project(
      'patch',
      {'path': '/work/actual.py'},
      {
        'success': true,
        'files_deleted': ['/work/actual.py'],
      },
    );
    expect(deleted.resourceTarget, isNull);
    expect(deleted.response.single.resourceTarget, isNull);
  });

  test('failed patch has no current-file action', () {
    final failed = project(
      'patch',
      {'path': '/work/actual.py'},
      {'success': false, 'error': 'No change was applied.'},
    );
    expect(failed.resourceTarget, isNull);
  });

  test('created then deleted patch file has no current-file action', () {
    final createdThenDeleted = project(
      'patch',
      {'mode': 'patch', 'patch': 'Requested patch'},
      {
        'success': true,
        'files_created': ['/work/transient.py'],
        'files_deleted': ['/work/transient.py'],
      },
    );
    expect(
      createdThenDeleted.response.every(
        (block) => block.resourceTarget == null,
      ),
      isTrue,
    );
  });

  test('patch no-change outranks files_modified bookkeeping', () {
    final noChange = project(
      'patch',
      {'path': '/work/file.py', 'old_string': 'old', 'new_string': ''},
      {
        'success': true,
        'no_change': true,
        'note': 'Already applied; no write performed.',
        'files_modified': ['/work/file.py'],
        'resolved_path': '/work/file.py',
      },
    );
    expect(noChange.receiptStatus, 'No change');
    expect(noChange.resourceTarget, isNull);
    expect(noChange.request.map((b) => b.text), ['old', '']);
    expect(noChange.request.last.copyable, isFalse);
    expect(noChange.response.map((b) => b.text), [
      'Already applied; no write performed.',
    ]);
  });

  test(
    'V4A keeps partial diff, deleted paths and per-file syntax findings',
    () {
      const patch =
          '*** Begin Patch\n*** Add File: /work/new.py\n+new\n*** End Patch';
      const diff = '--- /dev/null\n+++ b/work/new.py\n+new';
      final partial = project(
        'patch',
        {'mode': 'patch', 'patch': patch},
        {
          'success': false,
          'error': 'Apply phase failed; state may be inconsistent.',
          'diff': diff,
          'files_created': ['/work/new.py'],
          'files_deleted': ['/work/old.py'],
          'lint': {
            '/work/new.py': {
              'status': 'error',
              'output': 'SyntaxError: unexpected token',
            },
            '/work/other.py': {'status': 'skipped', 'message': 'Missing tool'},
          },
          'lsp_diagnostics':
              '<diagnostics file="/work/new.py">Actual finding</diagnostics>',
        },
      );
      expect(partial.request.single.text, patch);
      expect(partial.response.first.copyText, diff);
      expect(partial.response.first.copyable, isTrue);
      expect(
        partial.response
            .singleWhere((b) => b.label == 'Deleted')
            .resourceTarget,
        isNull,
      );
      expect(
        partial.response
            .singleWhere((b) => b.label == 'Syntax diagnostics')
            .facts,
        ['/work/new.py'],
      );
      expect(
        partial.response.map((b) => b.text),
        isNot(contains('Missing tool')),
      );
      expect(partial.receiptState, ToolReceiptState.error);
      expect(partial.resourceTarget, isNull);
      expect(
        partial.response
            .singleWhere((b) => b.label == 'Created')
            .resourceTarget,
        '/work/new.py',
      );
      expect(partial.metadata.any((s) => s.contains('verified')), isFalse);
    },
  );

  test('structured search groups excerpts with exact reusable copy scope', () {
    final search = project(
      'search_files',
      {'pattern': 'name', 'path': '/work', 'context': 1},
      {
        'total_count': 3,
        'matches': [
          {'path': '/work/a.py', 'line': 1, 'content': '# context'},
          {'path': '/work/a.py', 'line': 2, 'content': '  name = "demo"'},
          {'path': '/work/b.py', 'line': 9, 'content': 'name = "other"'},
        ],
        '_omitted': '2 credential-file results omitted.',
      },
    );
    expect(search.layout, ToolActivityLayout.search);
    expect(search.request.single.copyText, 'name');
    expect(search.headerFacts, ['Context: 1']);
    final group = search.response.first;
    expect(group.resourceTarget, '/work/a.py');
    expect(group.text, '1|# context\n2|  name = "demo"');
    expect(group.copyText, '# context\n  name = "demo"');
    expect(search.metadata, ['Reported rows: 3']);
    expect(search.response.last.text, '2 credential-file results omitted.');
    expect(search.response.last.copyable, isFalse);
  });

  test('dense grammar is validated and malformed data stays Raw', () {
    const format =
        "path-grouped: each file path on its own line, followed by indented '<line>: <content>' rows for matches in that file";
    final dense = project(
      'search_files',
      {'pattern': 'name'},
      {
        'total_count': 5,
        'matches_format': format,
        'matches_text':
            '/work/a.py\n  1: first\n  2:   indented\n/work/b.py\n  3: third',
      },
    );
    expect(dense.response.map((b) => b.resourceTarget), [
      '/work/a.py',
      '/work/b.py',
    ]);
    expect(dense.response.first.copyText, '  1: first\n  2:   indented');
    final malformed = project(
      'search_files',
      {'pattern': 'name'},
      {'matches_format': format, 'matches_text': '  1: orphan\n/work/a.py'},
    );
    expect(malformed.response.single.resourceTarget, isNull);
    expect(malformed.response.single.copyable, isFalse);
    expect(malformed.response.single.text, contains('Raw details'));
    expect(malformed.receiptState, ToolReceiptState.warning);
  });

  test(
    'search modes qualify counts and never invent directory file actions',
    () {
      final files = project(
        'search_files',
        {'pattern': '*', 'target': 'files', 'order': 'modified'},
        {
          'total_count': 3,
          'files': ['/work/app.py', '/work/directory'],
          'truncated': true,
          'total_count_is_lower_bound': true,
          'limit_reason': 'search_timeout',
          '_hint': 'Narrow the search.',
        },
      );
      expect(files.headerFacts, ['Target: files', 'Order: modified']);
      expect(files.metadata.first, 'Reported files: at least 3');
      expect(
        files.response.singleWhere((b) => b.label == 'Files').copyText,
        '/work/app.py\n/work/directory',
      );
      expect(files.response.every((b) => b.resourceTarget == null), isTrue);
    },
  );

  test('count search reports counts without inventing content', () {
    final counts = project(
      'search_files',
      {'pattern': 'name', 'output_mode': 'count'},
      {
        'total_count': 5,
        'counts': {'/work/a.py': 2, '/work/b.py': 3},
      },
    );
    expect(counts.response.map((b) => b.facts.single), [
      'Reported matches: 2',
      'Reported matches: 3',
    ]);
    expect(counts.response.every((b) => b.text.isEmpty && !b.copyable), isTrue);
  });

  test('failed search does not present reported match counts', () {
    final failed = project(
      'search_files',
      {'pattern': '['},
      {'total_count': 0, 'error': 'Invalid regex'},
    );
    expect(failed.metadata, isEmpty);
    expect(failed.response.single.label, 'Error');
  });

  test('unknown bookkeeping never gains generic main-card blocks', () {
    final read = project(
      'read_file',
      {'path': '/work/file.txt', 'unknown_option': 'private'},
      {
        'content': '1|received',
        'is_image': false,
        'not_found': false,
        'base64_content': 'not a public payload',
        'unknown_fact': {'arbitrary': 'value'},
      },
    );
    expect(read.request, isEmpty);
    expect(read.response.single.text, '1|received');
    expect(read.headerFacts, isEmpty);
  });
}
