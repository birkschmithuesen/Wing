import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/presentation/tool_activity_details.dart';

ToolActivityDetails project(String name, Object? input, Object? output) =>
    ToolActivityDetails.project(name: name, input: input, output: output);

void main() {
  test(
    'tool search keeps query, readable capability and connector identity',
    () {
      final details = project(
        'tool_search',
        {
          'queries': ['gmail fetch emails'],
          'limit': 5,
        },
        {
          'queries': ['gmail fetch emails'],
          'total_available': 900,
          'results': [
            {
              'query': 'gmail fetch emails',
              'matches': ['connectors__gmail__FETCH_EMAILS'],
            },
          ],
          'tools': {
            'connectors__gmail__FETCH_EMAILS': {
              'source': 'connectors',
              'source_name': 'gmail',
              'description': 'Fetch emails matching the supplied search.',
              'required': ['query'],
            },
          },
        },
      );
      expect(details.request.single.text, 'gmail fetch emails');
      expect(details.headerFacts, ['Limit: 5']);
      expect(details.response.single.label, 'Fetch emails');
      expect(details.response.single.facts, ['Source: gmail']);
      expect(
        details.response.single.text,
        'Fetch emails matching the supplied search.',
      );
      expect(details.response.single.copyable, isFalse);
      expect(details.metadata, isEmpty);
      expect(
        details.response.any((block) => block.text.contains('900')),
        isFalse,
      );
    },
  );

  test(
    'empty lexical match preserves source warning and hosted partial failure',
    () {
      final details = project(
        'tool_search',
        {
          'queries': ['tracker puppy'],
        },
        {
          'results': [
            {
              'query': 'tracker puppy',
              'matches': <String>[],
              'available_sources': [
                {
                  'name': 'archive',
                  'tool_count': 3,
                  'unavailable': 'Archive is offline.',
                },
              ],
              'hint': 'Try the service name and a concrete action.',
            },
          ],
          'tools': <String, Object?>{},
          'connectors': {
            'status': 'unavailable',
            'reason': 'sign_in_expired',
            'hint': 'Sign in again to search hosted connectors.',
          },
        },
      );
      expect(
        details.response.map((block) => block.text),
        containsAll([
          'No matching tools were returned.',
          'archive',
          'Archive is offline.',
          'Try the service name and a concrete action.',
          'Sign in again to search hosted connectors.',
        ]),
      );
      expect(details.receiptState, ToolReceiptState.warning);
      expect(details.response.every((block) => !block.copyable), isTrue);
    },
  );

  test(
    'describe omits parameter schema while retaining each unavailable result',
    () {
      final details = project(
        'tool_describe',
        {
          'names': [
            'mcp__tracker__create_issue',
            'mcp__archive__read',
            'terminal',
          ],
        },
        {
          'tools': {
            'mcp__tracker__create_issue': {
              'description': 'Create a tracker issue.',
              'parameters': {
                'type': 'object',
                'properties': {
                  'secret_schema_key': {'type': 'string'},
                },
              },
            },
          },
          'not_found': ['mcp__archive__read'],
          'errors': {'terminal': 'Call terminal directly.'},
          'hint': 'Refresh discovery.',
          'connectors': {
            'status': 'unavailable',
            'reason': 'unreachable',
            'names': ['connectors__gmail__FETCH_EMAILS'],
          },
        },
      );
      expect(details.request.map((block) => block.text), [
        'Create issue',
        'Read',
        'Terminal',
      ]);
      expect(
        details.response.map((block) => block.label),
        containsAll([
          'Create issue',
          'Read · Unavailable',
          'Terminal · Description unavailable',
          'Fetch emails · Description unavailable',
        ]),
      );
      expect(
        details.response.map((block) => block.text).join(),
        isNot(contains('secret_schema_key')),
      );
      expect(details.response.every((block) => !block.copyable), isTrue);
    },
  );

  test('connector batch preserves independent receipt and unstarted error', () {
    const body = 'Please review the proposal.\n  Preserve this spacing.\n';
    final details = project(
      'tool_call',
      {
        'calls': [
          {
            'name': 'connectors__gmail__SEND_EMAIL',
            'arguments': {'body': body, 'timeout': 20},
          },
          {
            'name': 'connectors__slack__POST_MESSAGE',
            'arguments': {'text': 'Ready'},
          },
        ],
      },
      {
        'results': [
          {
            'index': 0,
            'name': 'connectors__gmail__SEND_EMAIL',
            'response': 'A response was received.',
          },
          {
            'index': 1,
            'name': 'connectors__slack__POST_MESSAGE',
            'error': {
              'code': 'INTERRUPTED',
              'message': 'Stopped before this call was made.',
            },
          },
        ],
        'success_count': 1,
        'error_count': 1,
        'total_count': 2,
      },
    );
    expect(details.request.first.copyText, body);
    expect(details.request.first.copyable, isTrue);
    expect(details.request.first.facts, ['Source: gmail']);
    expect(details.request.any((block) => block.text.contains('20')), isFalse);
    expect(details.response.map((block) => block.label), [
      'Send email · Result',
      'Post message · Error',
    ]);
    expect(details.receiptState, ToolReceiptState.warning);
    expect(details.metadata, ['Responses: 1', 'Errors: 1', 'Operations: 2']);
    expect(details.response.last.copyable, isFalse);
  });

  test(
    'opaque connector status is received data without guessed domain success',
    () {
      final details = project(
        'tool_call',
        {
          'calls': [
            {
              'name': 'connectors__custom__CHECK_JOB',
              'arguments': {'job_id': 'job'},
            },
          ],
        },
        {
          'results': [
            {
              'index': 0,
              'name': 'connectors__custom__CHECK_JOB',
              'response': {
                'status': 'failed',
                'error': 'Domain record text',
                'structuredContent': {'message': 'Retain this data'},
              },
            },
          ],
          'success_count': 1,
          'error_count': 0,
          'total_count': 1,
        },
      );
      expect(details.request.single.text, 'Check job');
      expect(details.response.single.text, contains('Retain this data'));
      expect(details.response.single.text, contains('Domain record text'));
      expect(details.response.single.copyable, isFalse);
      expect(details.response.single.format, ToolDetailFormat.source);
      expect(details.receiptState, isNull);
      expect(details.receiptStatus, isNull);
      expect(details.metadata, isEmpty);
    },
  );

  test(
    'bridge validation schema stays raw while failure and recovery remain readable',
    () {
      final details = project(
        'tool_call',
        {
          'calls': [
            {
              'name': 'mcp__tracker__create_issue',
              'arguments': <String, Object?>{},
            },
          ],
        },
        {
          'error': 'Missing title. The tool was NOT invoked.',
          'parameters': {
            'required': ['title'],
            'properties': {'schema_only_key': {}},
          },
          'path': 'arguments',
          'constraint': 'required',
          'hint': 'Supply the required title.',
        },
      );
      expect(details.receiptState, ToolReceiptState.error);
      expect(
        details.response.map((block) => block.text),
        containsAll([
          'Missing title. The tool was NOT invoked.',
          'Supply the required title.',
        ]),
      );
      expect(
        details.response.map((block) => block.text).join(),
        isNot(contains('schema_only_key')),
      );
      expect(details.response.every((block) => !block.copyable), isTrue);
    },
  );

  test('clarify retains answered, skipped and unanswered after timeout', () {
    const answer = 'A complete report.\n\nKeep the actual receipt visible.\n';
    final details = project(
      'clarify',
      {
        'questions': [
          {'question': 'What should the report contain?'},
          {
            'question': 'Which format?',
            'choices': ['Markdown', 'Plain text'],
          },
          {'question': 'Who is the audience?'},
        ],
      },
      {
        'responses': [
          {
            'question': 'What should the report contain?',
            'choices_offered': null,
            'status': 'answered',
            'user_response': answer,
          },
          {
            'question': 'Which format?',
            'choices_offered': ['Markdown', 'Plain text'],
            'status': 'skipped',
            'user_response': null,
          },
          {
            'question': 'Who is the audience?',
            'choices_offered': null,
            'status': 'unanswered',
            'user_response': null,
          },
        ],
        'outcome': 'timed_out',
        'notice': 'Waiting ended.',
      },
    );
    expect(
      details.request.map((block) => block.text),
      contains('• Markdown\n• Plain text'),
    );
    expect(details.response.first.text, answer);
    expect(details.response.first.copyText, answer);
    expect(details.response.first.copyable, isTrue);
    expect(
      details.response.map((block) => block.text),
      containsAll(['Skipped', 'Unanswered', 'Waiting ended.']),
    );
    expect(details.receiptState, ToolReceiptState.warning);
    expect(
      details.response.where((block) => block.text == 'Waiting ended.'),
      hasLength(1),
    );
    expect(
      details.response.any((block) => block.text.contains('The wait ended')),
      isFalse,
    );
    expect(details.response.any((block) => block.text == 'null'), isFalse);
    expect(details.request.every((block) => !block.copyable), isTrue);
  });

  test(
    'clarify selected alternatives remain readable without JSON or option copy',
    () {
      final details = project(
        'clarify',
        {
          'questions': [
            {
              'question': 'Which checks?',
              'choices': ['Installation', 'Accessibility'],
              'multi_select': true,
            },
          ],
        },
        {
          'responses': [
            {
              'question': 'Which checks?',
              'choices_offered': ['Installation', 'Accessibility'],
              'status': 'answered',
              'user_response': ['Installation', 'Accessibility'],
            },
          ],
          'outcome': 'submitted',
        },
      );
      expect(details.response.single.text, '• Installation\n• Accessibility');
      expect(details.response.single.facts, ['Answered']);
      expect(details.response.single.copyable, isFalse);
      expect(details.receiptState, isNull);
      expect(details.headerFacts, isEmpty);
    },
  );

  test('tool_get has no current describe alias or schema projector', () {
    final details = project(
      'tool_get',
      {
        'names': ['terminal'],
      },
      {
        'tools': {
          'terminal': {
            'description': 'A stale tool description.',
            'parameters': {},
          },
        },
      },
    );
    expect(details.request, isEmpty);
    expect(details.response, isEmpty);
  });
}
