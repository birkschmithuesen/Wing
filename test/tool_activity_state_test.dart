import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/presentation/tool_activity_details.dart';
import 'package:wing/core/presentation/skill_document.dart';

ToolActivityDetails project(
  String name,
  Map<String, Object?> args,
  Object? result,
) => ToolActivityDetails.project(name: name, input: args, output: result);

void main() {
  test('skill receipt identifies changes without supplied inputs', () {
    final detail = project('skill_manage', {}, {
      'success': true,
      'operations_applied': 1,
      'results': [
        {
          'name': 'health-coaching',
          'action': 'patch',
          'file_path': 'references/analytics-collaboration.md',
          'success': true,
        },
      ],
    });
    expect(detail.intent, 'health-coaching');
    expect(detail.response.single.label, 'health-coaching');
    expect(detail.response.single.text, 'Patched');
    expect(detail.response.single.copyable, isFalse);
    expect(detail.response.single.resourceTarget, isNull);
    expect(
      detail.response.single.filenameTarget,
      'references/analytics-collaboration.md',
    );
  });

  test(
    'skill receipt preserves multiple identities and uncertain outcomes',
    () {
      for (final (extra, outcome) in [
        (<String, Object?>{}, 'Outcome unconfirmed'),
        (<String, Object?>{'success': false}, 'Batch failed'),
        (
          <String, Object?>{'success': true, 'staged': true},
          'Awaiting approval',
        ),
      ]) {
        final detail = project('skill_manage', {}, {
          ...extra,
          'results': [
            {'name': 'first', 'action': 'patch', 'success': true},
            {'name': 'second', 'action': 'write_file', 'success': true},
            {'name': 'first', 'action': 'edit', 'success': true},
            {'name': ' ', 'file_path': '', 'action': null},
            'invalid entry',
          ],
        });
        expect(detail.intent, 'first · second');
        expect(detail.response.take(3).map((b) => b.label), [
          'first',
          'second',
          'first',
        ]);
        expect(detail.response.take(3).every((b) => b.text == outcome), isTrue);
        expect(detail.response.every((b) => b.resourceTarget == null), isTrue);
        expect(detail.response.every((b) => !b.copyable), isTrue);
      }
    },
  );

  test('Hindsight submitted memory stays distinct from its actual receipt', () {
    const fact = 'The user prefers\nicon-only action buttons.\n';
    final details = project('hindsight_retain', {
      'content': fact,
      'context': 'UI preferences',
      'tags': ['wing', 'design'],
      'occurred_at': '2026-10-13T11:06:00Z',
    }, 'Memory stored successfully.');
    expect(details.request.single.label, 'Submitted memory');
    expect(details.request.single.text, fact);
    expect(details.request.single.copyText, fact);
    expect(details.response.single.label, 'Result');
    expect(details.response.single.text, 'Memory stored successfully.');
    expect(details.headerFacts, [
      'Context: UI preferences',
      'Tags: wing · design',
      'Occurred: 2026-10-13T11:06:00Z',
    ]);
    expect(details.metadata, isEmpty);
    expect(details.request.single.label, isNot('Retained fact'));
  });

  test('Hindsight pending, empty and failed receipts preserve uncertainty', () {
    final pending = project('hindsight_retain', {
      'content': 'A new fact',
    }, null);
    expect(pending.request.single.text, 'A new fact');
    expect(pending.response, isEmpty);
    expect(pending.receiptState, isNull);
  });

  test('Hindsight absent submitted content does not invent a request', () {
    final empty = project(
      'hindsight_retain',
      {},
      'Memory stored successfully.',
    );
    expect(empty.request, isEmpty);
  });

  test('Hindsight failed receipt preserves submitted intent', () {
    final failed = project(
      'hindsight_retain',
      {'content': 'A new fact'},
      {
        'success': false,
        'error': 'Failed to store memory: service unavailable',
      },
    );
    expect(failed.receiptState, ToolReceiptState.error);
    expect(failed.response.single.text, contains('service unavailable'));
    expect(failed.request.single.label, 'Submitted memory');
  });

  test(
    'skill declaration tags match stock across activity and administration',
    () {
      for (final declaration in [
        'tags: [review, evidence]',
        'tags: review, evidence',
        'tags: "[review, evidence]"',
        'tags: [review, evidence]\nmetadata:\n  hermes:\n    tags: []',
      ]) {
        final document = SkillDocument.fromReceived(
          name: 'review',
          content: '---\n$declaration\n---\n# Review',
        );
        expect(document.tags, ['review', 'evidence']);
        expect(() => document.tags.add('invented'), throwsUnsupportedError);
      }
      expect(
        SkillDocument.fromReceived(
          name: 'review',
          content: '---\ntags: [review]\n---\n# Review',
          tags: const [],
        ).tags,
        isEmpty,
      );
    },
  );
  test(
    'front-matter-only skill retains identity, description and exact raw content',
    () {
      const content =
          '---\nname: review\ndescription: Inspect actual evidence.\n---\n';
      final detail = project(
        'skill_view',
        {'name': 'review'},
        {
          'success': true,
          'name': 'review',
          'description': 'Inspect actual evidence.',
          'content': content,
        },
      );
      expect(detail.skill!.document.name, 'review');
      expect(detail.skill!.document.description, 'Inspect actual evidence.');
      expect(detail.skill!.document.formattedContent, isEmpty);
      expect(detail.response.single.copyText, content);
      expect(identical(detail.response.single, detail.skill!.content), isTrue);
    },
  );
  test('main skill hides YAML from prose while preserving exact raw content', () {
    const raw =
        '---\nname: inspect-build\ndescription: Inspect a build\n---\n# Inspect build\n\nRead the logs.\n';
    final main = project(
      'skill_view',
      {'name': 'inspect-build'},
      {'content': raw},
    );
    expect(main.response.single.text, '# Inspect build\n\nRead the logs.\n');
    expect(main.response.single.copyText, raw);
    final support = project(
      'skill_view',
      {'name': 'inspect-build', 'file_path': 'notes.md'},
      {'file': 'notes.md', 'content': raw},
    );
    expect(support.response.single.text, raw);
  });

  test('cron error and shared session context appear once', () {
    final cron = project(
      'cronjob_manage',
      {'action': 'run'},
      {
        'success': true,
        'job': {
          'execution_success': false,
          'execution_error': 'Script failed',
          'last_error': 'Script failed',
          'last_delivery_error': 'Delivery failed',
        },
      },
    );
    expect(cron.response.where((b) => b.text == 'Script failed'), hasLength(1));
    expect(cron.response.any((b) => b.text == 'Delivery failed'), isTrue);
  });

  test('session shared context appears once', () {
    final session = project(
      'session_search',
      {'session_id': 's'},
      {
        'mode': 'read',
        'session_meta': {'title': 'Trip planning', 'when': 'Today'},
        'messages': [
          {'role': 'user', 'content': 'Question'},
          {'role': 'assistant', 'content': 'Answer'},
        ],
      },
    );
    expect(
      session.headerFacts.where((f) => f == 'Trip planning'),
      hasLength(1),
    );
    expect(
      session.response.expand((b) => b.facts),
      isNot(contains('Trip planning')),
    );
    expect(session.response.map((b) => b.text), ['Question', 'Answer']);
  });

  test('mixed child results retain failure and absent-summary identity', () {
    final detail = project(
      'delegate_task',
      {
        'tasks': [
          {'goal': 'First'},
          {'goal': 'Second'},
        ],
      },
      {
        'results': [
          {
            'task_index': 0,
            'status': 'failed',
            'summary': null,
            'error': 'Quota',
          },
          {
            'task_index': 1,
            'status': 'interrupted',
            'summary': 'Partial output',
          },
        ],
      },
    );
    expect(detail.receiptState, ToolReceiptState.error);
    expect(detail.receiptStatus, 'Child failed');
    final empty = detail.response.firstWhere((b) => b.facts.contains('Task 1'));
    expect(empty.facts, contains('Failed'));
    expect(empty.copyable, isFalse);
    expect(empty.text, 'No result received');
  });

  test(
    'memory effective content preserves whitespace and stock precedence',
    () {
      final detail = project(
        'memory',
        {
          'action': 'replace',
          'old_text': 'old',
          'content': '  ',
          'new_text': 'Ignored alternate.',
        },
        {'success': false, 'error': 'content cannot be empty.'},
      );
      expect(detail.request.map((b) => b.text), ['old', '  ']);
      expect(detail.receiptState, ToolReceiptState.error);
    },
  );

  test('memory keeps whole-entry intent and actual previous entries exact', () {
    const old = 'old substring';
    const replacement = '  New whole entry.\n';
    const previous =
        'The actual old substring was only part of this full entry.';
    final detail = project(
      'memory',
      {
        'target': 'memory',
        'operations': [
          {'action': 'replace', 'old_text': old, 'content': replacement},
          {'action': 'add', 'content': 'Existing duplicate.'},
        ],
      },
      {
        'success': true,
        'done': true,
        'message': 'Applied 2 operation(s).',
        'entry_count': 3,
        'replaced_entries': {'1': previous},
        'note': 'Write saved. This update is complete — do not repeat it.',
      },
    );
    expect(detail.request.map((b) => b.copyText), [
      old,
      replacement,
      'Existing duplicate.',
    ]);
    expect(detail.response.where((b) => b.copyable).single.copyText, previous);
    expect(detail.response.where((b) => b.copyable).single.facts, [
      'Operation 1',
    ]);
    expect(detail.metadata, ['Entries: 3']);
    expect(detail.response.any((b) => b.text.contains('Write saved')), isFalse);
    expect(detail.response.any((b) => b.text.contains('changed')), isFalse);
  });

  test(
    'memory duplicate and staged results never imply applied new content',
    () {
      final duplicate = project(
        'memory',
        {'action': 'add', 'content': 'Same.'},
        {
          'success': true,
          'done': true,
          'message': 'Entry already exists (no duplicate added).',
        },
      );
      expect(duplicate.response.single.text, contains('no duplicate added'));
      expect(duplicate.response.single.copyable, isFalse);
    },
  );

  test('memory staged results remain awaiting approval', () {
    final staged = project(
      'memory',
      {'target': 'user', 'action': 'remove', 'old_text': 'old'},
      {
        'success': true,
        'staged': true,
        'pending_id': 'pending-id',
        'message': 'Proposed write awaits approval.',
      },
    );
    expect(staged.receiptStatus, 'Awaiting approval');
    expect(staged.response.map((b) => b.text), [
      'Proposed write awaits approval.',
    ]);
  });

  test(
    'skill uses actual requested name and Result with useful-only payload actions',
    () {
      const content = '# Loaded skill\n\nKeep exact whitespace.  \n';
      final detail = project(
        'skill_view',
        {'name': 'plugin:requested-skill'},
        {
          'success': true,
          'name': 'canonical-skill',
          'content': content,
          'description': 'Catalog description',
          'tags': ['tag'],
          'required_commands': [],
          'setup_needed': false,
          'setup_skipped': false,
          'readiness_status': 'available',
          '_source_path': '/skills/actual/SKILL.md',
        },
      );
      expect(detail.intent, 'plugin:requested-skill');
      expect(detail.response.single.label, 'Result');
      expect(detail.response.single.copyText, content);
      expect(detail.response.single.markdown, isTrue);
      expect(detail.response.single.resourceTarget, '/skills/actual/SKILL.md');
      expect(detail.skill!.document.name, 'canonical-skill');
      expect(detail.skill!.document.description, 'Catalog description');
      expect(detail.skill!.document.tags, ['tag']);
      expect(detail.skill!.document.metadata, isEmpty);
      expect(identical(detail.skill!.content, detail.response.single), isTrue);
      expect(
        detail.response.any((b) => b.text.contains('Catalog description')),
        isFalse,
      );
    },
  );

  test('binary skill receipts do not offer text actions', () {
    final binary = project(
      'skill_view',
      {'name': 's', 'file_path': 'assets/a.bin'},
      {
        'success': true,
        'is_binary': true,
        'content': '[Binary file: a.bin, size: 24 bytes]',
      },
    );
    expect(binary.response.single.copyable, isFalse);
    expect(binary.response.single.resourceTarget, isNull);
    expect(binary.skill, isNull);
  });

  test('skill support source and unchanged stub keep receipt scope', () {
    final source = project(
      'skill_view',
      {'name': 's', 'file_path': 'scripts/check.py'},
      {
        'success': true,
        'content': 'print("# literal")\n',
        'file': 'scripts/check.py',
      },
    );
    expect(source.response.single.format, ToolDetailFormat.source);
    expect(source.response.single.markdown, isFalse);
    expect(source.skill, isNull);
  });

  test('unchanged skill stub retains receipt scope', () {
    final unchanged = project(
      'skill_view',
      {'name': 's'},
      {
        'success': true,
        'status': 'unchanged',
        'dedup': true,
        'content_returned': false,
        'message': 'Skill content unchanged since it was loaded earlier.',
      },
    );
    expect(unchanged.receiptStatus, 'Unchanged');
    expect(unchanged.response.single.copyable, isFalse);
    expect(unchanged.response.single.label, 'Result');
    expect(unchanged.skill, isNull);
  });

  test('skill metadata is supplied, typed and separate from instructions', () {
    const raw =
        '---\nname: review\nversion: 1.0\nauthor: Example\nlicense: MIT\n---\n# Review\nRead the evidence.';
    final detail = project(
      'skill_view',
      {'name': 'review'},
      {
        'name': 'review',
        'content': raw,
        'metadata': {
          'version': '2.0',
          'author': ['not a name'],
        },
        'tags': ['review', 10, '', 'evidence'],
      },
    );
    expect(detail.skill!.document.tags, ['review', 'evidence']);
    expect(detail.skill!.document.metadata, [(label: 'Version', value: '2.0')]);
    expect(detail.skill!.document.description, isNull);
    expect(detail.skill!.content.copyText, raw);
  });

  test('malformed skill metadata retains readable content', () {
    final malformed = project(
      'skill_view',
      {'name': 'review'},
      {'content': '---\nauthor: [\n---\n# Still readable'},
    );
    expect(malformed.skill!.document.metadata, isEmpty);
    expect(malformed.skill!.content.text, '# Still readable');
  });

  test(
    'skill patch separates exact Find and Replace and preserves empty deletion',
    () {
      const find = '  exact old\n';
      final detail = project(
        'skill_manage',
        {
          'operations': [
            {
              'action': 'patch',
              'name': 'supplied-skill',
              'old_string': find,
              'new_string': '',
              'replace_all': true,
            },
          ],
        },
        {
          'success': true,
          'operations_applied': 1,
          'results': [
            {
              'name': 'supplied-skill',
              'action': 'patch',
              'file_path': null,
              'success': true,
            },
          ],
        },
      );
      expect(detail.intent, 'supplied-skill');
      expect(detail.request.map((b) => b.label), [
        'supplied-skill',
        'Replace with',
      ]);
      expect(detail.request.first.copyText, find);
      expect(detail.request.last.text, '');
      expect(detail.request.last.copyable, isFalse);
      expect(detail.response.single.text, 'Patched');
      expect(detail.metadata, ['Operations applied: 1']);
    },
  );

  test(
    'skill failed batch retains rollback and partial recovery without change claims',
    () {
      final detail = project(
        'skill_manage',
        {
          'operations': [
            {
              'action': 'remove_file',
              'name': 's',
              'file_path': 'references/a.md',
            },
          ],
        },
        {
          'success': false,
          'error': 'Batch aborted; all touched skills rolled back.',
          'failed_index': 0,
          'completed_before_failure': 0,
          'file_preview': '# Partial file...',
        },
      );
      expect(detail.receiptState, ToolReceiptState.error);
      expect(detail.metadata, [
        'Failed operation: 1',
        'Operations attempted before failure: 0',
      ]);
      expect(detail.response.first.label, 'File excerpt');
      expect(detail.response.last.text, contains('rolled back'));
    },
  );

  test(
    'task snapshots preserve passive status and parent hierarchy without edit actions',
    () {
      final detail = project(
        'todo_list',
        {'todos': [], 'merge': false},
        {
          'revision': 9,
          'todos': [
            {
              'id': 'p',
              'content': 'Inspect actual output',
              'status': 'completed',
            },
            {
              'id': 'c',
              'content': 'Recover after failure',
              'status': 'cancelled',
              'parent': 'p',
            },
          ],
          'summary': {
            'total': 2,
            'pending': 0,
            'in_progress': 0,
            'completed': 1,
            'cancelled': 1,
          },
        },
      );
      expect(detail.intent, 'Clear tasks');
      expect(detail.response.map((b) => b.text), [
        'Inspect actual output',
        'Recover after failure',
      ]);
      expect(detail.response.last.facts, ['Cancelled', 'Parent: p']);
      expect(
        detail.response.every(
          (b) => b.role == ToolDetailRole.task && !b.copyable,
        ),
        isTrue,
      );
      expect(detail.response.any((b) => b.text.contains('revision')), isFalse);
    },
  );

  test(
    'delegation dispatch mixed indices and unvalidated partial results retain qualifiers',
    () {
      const summary = '# Findings\n\nInspected two files.\n';
      final detail = project(
        'delegate_task',
        {
          'tasks': [
            {'goal': 'A'},
            {'goal': 'B'},
            {'goal': 'C'},
          ],
        },
        {
          'status': 'dispatched',
          'mode': 'background',
          'count': 3,
          'inline_results': [
            {
              'task_index': 2,
              'status': 'completed',
              'summary': summary,
              'exit_reason': 'max_iterations',
              'truncated': true,
              'schema_valid': false,
              'schema_errors': ['Expected JSON object.'],
            },
          ],
        },
      );
      expect(detail.request.map((b) => b.copyText), ['A', 'B', 'C']);
      expect(detail.response.where((b) => b.copyable).single.copyText, summary);
      expect(detail.response.where((b) => b.copyable).single.facts, [
        'Task 3',
        'Completed',
      ]);
      expect(detail.response.any((b) => b.label == 'Partial result'), isTrue);
      expect(
        detail.response.any((b) => b.label == 'Unvalidated result'),
        isTrue,
      );
      expect(
        detail.response.any((b) => b.text == 'Dispatched in background.'),
        isTrue,
      );
      expect(detail.receiptState, ToolReceiptState.warning);
    },
  );

  test(
    'delegation has no legacy goal fallback and control admission is qualified',
    () {
      final oldInput = project(
        'delegate_task',
        {'goal': 'Unadvertised old input'},
        {'error': 'No tasks.'},
      );
      expect(oldInput.request, isEmpty);
    },
  );

  test('queued steering remains pending delivery', () {
    final steer = project(
      'delegate_task',
      {'action': 'steer', 'message': '  Check receipt.\n'},
      {'status': 'queued'},
    );
    expect(steer.request.single.copyText, '  Check receipt.\n');
    expect(
      steer.response.single.text,
      contains('delivery to the child is pending'),
    );
    expect(steer.response.single.copyable, isFalse);
  });

  test('requested stop remains potentially stopping', () {
    final stopped = project(
      'delegate_task',
      {'action': 'stop'},
      {'status': 'interrupt_requested'},
    );
    expect(stopped.response.single.text, contains('may still be stopping'));
  });

  test(
    'cron background, skipped and inner failure override generic success receipt',
    () {
      final background = project(
        'cronjob_manage',
        {'action': 'run', 'job_id': 'j'},
        {
          'success': true,
          'job': {
            'name': 'Job',
            'executed': true,
            'execution_mode': 'background',
          },
        },
      );
      expect(background.receiptStatus, 'Running in background');
      expect(
        background.response.single.text,
        contains('completion is pending'),
      );
    },
  );

  test('cron skipped execution overrides generic success', () {
    final skipped = project(
      'cronjob_manage',
      {'action': 'run', 'job_id': 'j'},
      {
        'success': true,
        'job': {
          'executed': false,
          'execution_success': false,
          'execution_skipped': 'Already being fired.',
        },
      },
    );
    expect(skipped.receiptStatus, 'Run skipped');
    expect(skipped.receiptState, isNot(ToolReceiptState.error));
  });

  test('cron inner failure overrides generic success', () {
    final failed = project(
      'cronjob_manage',
      {'action': 'run', 'job_id': 'j'},
      {
        'success': true,
        'job': {
          'executed': true,
          'execution_success': false,
          'execution_error': 'Script failed.',
        },
      },
    );
    expect(failed.receiptState, ToolReceiptState.error);
    expect(failed.response.single.text, 'Script failed.');
  });

  test(
    'cron saved schedule and actual delivery uncertainty do not create job controls',
    () {
      final detail = project(
        'cronjob_manage',
        {
          'action': 'create',
          'prompt': '# Brief\nCollect reports.',
          'schedule': 'every day',
        },
        {
          'success': true,
          'gateway_running': false,
          'warning': 'Gateway not running; saved job will not fire.',
          'job': {
            'name': 'Brief',
            'prompt_preview': 'Collect reports.',
            'schedule': 'daily',
            'repeat': 'forever',
            'deliver': 'local',
            'state': 'scheduled',
            'last_delivery_unverified': true,
          },
        },
      );
      expect(detail.request.single.copyText, '# Brief\nCollect reports.');
      expect(
        detail.response.any((b) => b.text.contains('will not fire')),
        isTrue,
      );
      expect(
        detail.response.any(
          (b) => b.text.contains('Delivery completion is unverified'),
        ),
        isTrue,
      );
      expect(
        detail.response.where((b) => b.copyable).single.label,
        'Prompt excerpt',
      );
      expect(detail.response.any((b) => b.text == 'false'), isFalse);
    },
  );

  test('retired cron tool name does not create a receipt', () {
    final stale = project(
      'cronjob',
      {'action': 'run'},
      {
        'success': true,
        'job': {'executed': true},
      },
    );
    expect(stale.response, isEmpty);
  });

  test(
    'session discovery preserves actual message ownership and deduplicates bookends',
    () {
      const message = '  Exact received answer.\n';
      final detail = project(
        'session_search',
        {'query': 'error', 'limit': 3},
        {
          'success': true,
          'mode': 'discover',
          'count': 1,
          'results': [
            {
              'session_id': 'child',
              'parent_session_id': 'root',
              'link': '@session:sample/child',
              'title': 'Investigation',
              'detail': 'full',
              'bookend_start': [
                {'id': 1, 'role': 'assistant', 'content': message},
              ],
              'messages': [
                {
                  'id': 1,
                  'role': 'assistant',
                  'content': message,
                  'anchor': true,
                },
              ],
              'bookend_end': [],
              'snippet': 'Exact excerpt',
            },
          ],
        },
      );
      expect(detail.request.single.copyText, 'error');
      expect(detail.response.single.copyText, message);
      expect(detail.response.single.facts, contains('Parent session: root'));
      expect(detail.response.single.resourceTarget, isNull);
      expect(detail.response.single.link, isNull);
    },
  );

  test('session all four modes expose selected payload and server limits', () {
    final read = project(
      'session_search',
      {'session_id': 's'},
      {
        'success': true,
        'mode': 'read',
        'message_count': 45,
        'truncated': true,
        'message': 'First 20 and last 10 messages returned.',
        'messages': [
          {
            'id': 1,
            'role': 'tool',
            'content': '# literal tool output',
            'content_truncated': true,
          },
        ],
      },
    );
    expect(read.response.first.format, ToolDetailFormat.source);
    expect(read.response.first.markdown, isFalse);
    expect(read.response.first.facts, contains('Received excerpt'));
    expect(read.response.last.label, 'Partial session');
  });

  test('session scroll retains rebound warning and tool ownership', () {
    final scroll = project(
      'session_search',
      {'session_id': 'parent', 'around_message_id': 2},
      {
        'success': true,
        'mode': 'scroll',
        'session_id': 'child',
        'messages': [
          {
            'id': 2,
            'role': 'assistant',
            'content': null,
            'tool_calls': [
              {
                'function': {'name': 'read_file', 'arguments': '{}'},
              },
            ],
          },
        ],
        'warning': 'Rebound to child session.',
        'messages_before': 1,
        'messages_after': 0,
      },
    );
    expect(scroll.response.first.label, 'Tool requested');
    expect(scroll.response.first.copyable, isFalse);
    expect(scroll.response.last.text, 'Rebound to child session.');
  });

  test('session browse reports no recent sessions', () {
    final browse = project('session_search', {}, {
      'success': true,
      'mode': 'browse',
      'results': [],
      'count': 0,
    });
    expect(browse.response.single.text, 'No recent sessions.');
  });

  test('empty discovery preserves incomplete index warning', () {
    final empty = project(
      'session_search',
      {'query': 'missing'},
      {
        'success': true,
        'mode': 'discover',
        'results': [],
        'count': 0,
        'index_rebuild': {
          'percent': 40,
          'note': 'Older messages may be missing while index rebuilds.',
        },
      },
    );
    expect(empty.response.map((b) => b.text), [
      'No matching sessions.',
      'Older messages may be missing while index rebuilds.',
    ]);
    expect(empty.receiptState, ToolReceiptState.warning);
  });
}
