import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/presentation/tool_activity_details.dart';

ToolActivityDetails project(String name, Object? input, Object? output) =>
    ToolActivityDetails.project(name: name, input: input, output: output);

void main() {
  test(
    'navigate preserves actual resource and requested redirect without invented snapshot',
    () {
      final details = project(
        'browser_navigate',
        {'url': 'https://example.org/login'},
        {
          'success': true,
          'url': 'https://example.org/account',
          'title': 'Account',
          'used_real_profile': true,
        },
      );
      expect(details.intent, 'https://example.org/login');
      expect(details.resourceTarget, 'https://example.org/account');
      expect(details.response, isEmpty);
      expect(details.headerFacts, [
        'Page: Account',
        'Requested: https://example.org/login',
      ]);
      expect(details.metadata, ['Used real browser profile']);
      expect(details.images, isEmpty);
    },
  );

  test(
    'snapshot keeps exact partial tree, dialogs and separately partial frame inventory',
    () {
      const tree =
          '- button "Continue" [ref=e1]\n\n'
          '[... 40 more lines truncated — full snapshot: read_file '
          'path="/workspace/cache/browser.txt" offset=2 limit=200]';
      final details = project(
        'browser_snapshot',
        {'full': true},
        {
          'success': true,
          'snapshot': tree,
          'element_count': 41,
          'pending_dialogs': [
            {
              'id': 'dialog',
              'type': 'prompt',
              'message': 'Name the draft.',
              'default_prompt': 'Draft',
              'opened_at': 400,
            },
          ],
          'recent_dialogs': [
            {
              'type': 'confirm',
              'message': 'Use this draft?',
              'closed_by': 'auto_policy',
            },
          ],
          'frame_tree': {
            'truncated': true,
            'top': {'url': 'https://example.org'},
          },
        },
      );
      expect(details.resourceTarget, isNull);
      expect(details.response.first.text, tree);
      expect(details.response.first.copyText, tree);
      expect(details.response.first.copyable, isTrue);
      expect(details.response.first.format, ToolDetailFormat.source);
      expect(details.response.first.facts, [
        'Elements: 41',
        'Partial snapshot returned',
      ]);
      expect(details.response[1].facts, ['Default: Draft']);
      expect(details.response[1].copyable, isFalse);
      expect(details.response[2].facts, ['Closed automatically']);
      expect(details.response[2].text, 'Use this draft?');
      expect(details.metadata, ['Frame inventory partial']);
      expect(details.headerFacts, ['Full tree requested: true']);
    },
  );

  test(
    'empty snapshot remains empty receipt without invented navigation failure',
    () {
      final details = project('browser_snapshot', {}, {
        'success': true,
        'snapshot': '',
        'element_count': 0,
      });
      expect(details.response, isEmpty);
      expect(details.metadata, ['No page content returned']);
      expect(details.receiptState, isNull);
      expect(details.resourceTarget, isNull);
    },
  );

  test(
    'click acknowledgement preserves reported normalized target and no copy',
    () {
      final details = project(
        'browser_click',
        {'ref': 'e2'},
        {
          'success': true,
          'clicked': '@e2',
          'fallback_warning': 'Chrome performed the click after fallback.',
        },
      );
      expect(details.intent, 'Click e2');
      expect(details.response.first.text, 'Clicked @e2');
      expect(details.response.first.copyable, isFalse);
      expect(
        details.response.last.text,
        'Chrome performed the click after fallback.',
      );
      expect(details.receiptState, ToolReceiptState.warning);
      expect(details.resourceTarget, isNull);
    },
  );

  test('type has one exact copy for identical redacted payload', () {
    final redacted = project(
      'browser_type',
      {'ref': '@e1', 'text': '[REDACTED]'},
      {'success': true, 'typed': '[REDACTED]', 'element': '@e1'},
    );
    expect(redacted.request.single.copyText, '[REDACTED]');
    expect(redacted.request.single.copyable, isTrue);
    expect(redacted.response.single.text, 'Entered text in @e1.');
    expect(redacted.response.single.copyable, isFalse);
  });
  test(
    'type preserves separately redacted output when it differs from input',
    () {
      final different = project(
        'browser_type',
        {'ref': '@e1', 'text': 'supplied text'},
        {'success': true, 'typed': '[REDACTED]', 'element': '@e1'},
      );
      expect(different.response.first.copyText, '[REDACTED]');
    },
  );
  test('type exposes an explicit clear receipt without fabricated copy', () {
    final clear = project(
      'browser_type',
      {'ref': '@e1', 'text': ''},
      {'success': true, 'typed': '', 'element': '@e1'},
    );
    expect(clear.request.single.copyable, isFalse);
    expect(clear.response.single.text, 'Cleared @e1.');
  });
  test('failed type exposes only the received failure', () {
    final failed = project(
      'browser_type',
      {'ref': '@e1', 'text': ''},
      {'success': false, 'typed': '', 'error': 'Field missing.'},
    );
    expect(failed.response.map((block) => block.text), ['Field missing.']);
    expect(failed.metadata, isEmpty);
  });

  test(
    'search preserves source excerpt and rescue explanation without routing plumbing',
    () {
      const excerpt = '  Exact excerpt.\n';
      final details = project(
        'web_search',
        {'query': 'privacy', 'limit': 2},
        {
          'success': true,
          'data': {
            'web': [
              {
                'title': 'Privacy',
                'url': 'https://example.org/privacy',
                'description': excerpt,
                'position': 1,
              },
              {
                'title': 'Documentation',
                'url': 'https://docs.example.org',
                'description': '',
                'markdown': '# Received documentation\n',
              },
            ],
            'backend_error':
                'The configured backend timed out; alternate results were returned.',
            'rescued_from': 'provider',
            'served_by': 'other-provider',
          },
        },
      );
      expect(details.response.first.copyText, excerpt);
      expect(
        details.response.first.link.toString(),
        'https://example.org/privacy',
      );
      expect(details.response.first.link?.host, 'example.org');
      expect(details.response.first.facts, isEmpty);
      expect(details.response[1].text, '# Received documentation\n');
      expect(details.response[1].markdown, isTrue);
      expect(details.response.last.copyable, isFalse);
      expect(details.receiptState, ToolReceiptState.warning);
      expect(details.headerFacts, ['Limit: 2']);
      expect(details.metadata, isEmpty);
      expect(
        details.response.map((block) => block.text).join(),
        isNot(contains('other-provider')),
      );
    },
  );

  test(
    'identity-only and unsupported web sources have no fabricated excerpt copy',
    () {
      final details = project(
        'web_search',
        {'query': 'guide'},
        {
          'data': {
            'web': [
              {
                'title': 'Guide',
                'url': 'https://example.org/guide',
                'description': '',
              },
              {
                'title': 'Unsupported',
                'url': 'javascript:alert(1)',
                'description': 'Actual excerpt',
              },
            ],
          },
        },
      );
      expect(details.response.first.text, '');
      expect(details.response.first.copyable, isFalse);
      expect(details.response.first.link, isNotNull);
      expect(details.response.last.link, isNull);
      expect(details.resourceFor('javascript:alert(1)'), isNull);
    },
  );

  test(
    'extract keeps exact partial Markdown, 404 and source-specific failures',
    () {
      const content =
          '# Head\n\n[... middle omitted — see footer ...]\n\nTail\n\n'
          '──────── [TRUNCATED] ────────\n'
          'Full text could not be stored; re-run web_extract.\n';
      final details = project(
        'web_extract',
        {
          'urls': [
            'https://example.org/page',
            'https://example.org/missing',
            'https://example.org/slow',
          ],
          'char_limit': 2000,
        },
        {
          'results': [
            {
              'url': 'https://example.org/page',
              'title': 'Page',
              'content': content,
              'error': null,
            },
            {
              'url': 'https://example.org/missing',
              'title': '404 Not Found',
              'content': '# 404 Not Found\nThe page is missing.',
              'error': null,
            },
            {
              'url': 'https://example.org/slow',
              'content': '',
              'error': 'Extract timed out.',
            },
          ],
        },
      );
      expect(details.response.first.copyText, content);
      expect(details.response.first.markdown, isTrue);
      expect(details.response.first.facts, contains('Partial page returned'));
      expect(details.response[1].facts, contains('Returned a 404 page'));
      expect(details.response.last.text, 'Extract timed out.');
      expect(details.response.last.copyable, isFalse);
      expect(details.receiptState, ToolReceiptState.warning);
      expect(details.images, isEmpty);
    },
  );
  test('extract reports an error when every source fails', () {
    final allFailed = project('web_extract', {}, {
      'results': [
        {'url': 'https://example.org/slow', 'error': 'Timed out.'},
      ],
    });
    expect(allFailed.receiptState, ToolReceiptState.error);
  });

  test('desktop read keeps requested count and actual partial window', () {
    const text = '  Account settings\n';
    final read = project(
      'desktop_preview',
      {'action': 'read', 'start': 120, 'count': 20},
      {
        'kind': 'url',
        'url': 'https://example.org/account',
        'title': 'Account',
        'text': text,
        'start': 120,
        'end': 140,
        'total_chars': 800,
      },
    );
    expect(read.headerFacts, ['Start: 120', 'Count: 20', 'Page: Account']);
    expect(read.response.single.copyText, text);
    expect(read.response.single.format, ToolDetailFormat.prose);
    expect(read.response.single.facts, [
      'Characters 120–140 of 800',
      'Partial preview returned',
    ]);
  });
  test('desktop file preview preserves exact resource identity', () {
    final file = project(
      'desktop_preview',
      {'action': 'read'},
      {
        'kind': 'file',
        'url': 'file:///workspace/report.md',
        'path': '/workspace/report.md',
        'title': 'report.md',
        'text': '',
        'start': 0,
        'end': 0,
        'total_chars': 0,
        'note': 'Read the file itself with read_file.',
      },
    );
    expect(file.resourceTarget, '/workspace/report.md');
    expect(
      file.resourceFor(file.resourceTarget!)?.path,
      '/workspace/report.md',
    );
    expect(file.response.single.text, 'Read the file itself with read_file.');
    expect(file.response.single.copyable, isFalse);
    expect(file.images, isEmpty);
  });

  test(
    'desktop open exposes acknowledgement without claiming rendered page',
    () {
      final open = project(
        'desktop_preview',
        {'action': 'open', 'url': 'example.org'},
        {'success': true, 'url': 'https://example.org', 'label': 'Account'},
      );
      expect(open.resourceTarget, 'https://example.org');
      expect(open.response.single.text, 'Preview open request accepted.');
      expect(open.response.single.copyable, isFalse);
    },
  );
  test('desktop close reports acknowledgement without a resource', () {
    final close = project(
      'desktop_preview',
      {'action': 'close'},
      {'success': true, 'closed': 'all'},
    );
    expect(
      close.response.single.text,
      'Close request accepted for all previews.',
    );
    expect(close.resourceTarget, isNull);
    expect(close.headerFacts, isEmpty);
  });

  test(
    'drive sparse deltas show newly available and cleared values without baseline guesses',
    () {
      final details = project(
        'drive_preview',
        {'action': 'type', 'ref': 'notes', 'text': ''},
        {
          'success': true,
          'acted': 'typed into Notes',
          'delta': {
            'changed': [
              {'ref': 'notes', 'value': ''},
              {'ref': 'save', 'disabled': false},
            ],
            'removed': ['old-label'],
            'rebound': ['notes'],
            'same': 4,
          },
          'note': 'The page changed before it could be re-read.',
        },
      );
      expect(details.intent, 'Clear field notes');
      expect(details.request.single.copyable, isFalse);
      expect(details.response.first.text, 'typed into Notes');
      expect(
        details.response[1].text,
        '[notes] value: (cleared)\n[save] (available)',
      );
      expect(details.response[1].copyable, isFalse);
      expect(
        details.response.last.text,
        'The page changed before it could be re-read.',
      );
      expect(details.metadata, [
        'Removed references: old-label',
        'Unchanged surveyed elements: 4',
      ]);
      expect(details.resourceTarget, isNull);
      expect(
        details.response.map((block) => block.text).join(),
        isNot(contains('textbox')),
      );
    },
  );

  test('drive full inventory retains actual reported elements', () {
    final inventory = project(
      'drive_preview',
      {'action': 'elements', 'max': 20},
      {
        'elements': [
          {
            'ref': 'save',
            'role': 'button',
            'label': 'Save',
            'disabled': true,
            'selector': '#save',
          },
        ],
      },
    );
    expect(inventory.headerFacts, ['Limit: 20']);
    expect(inventory.response.single.text, '[save] button Save (unavailable)');
    expect(inventory.response.single.copyable, isFalse);
    expect(inventory.images, isEmpty);
  });
  test('drive key press retains its requested target', () {
    final press = project('drive_preview', {
      'action': 'press',
      'ref': 'search',
      'key': 'Enter',
    }, null);
    expect(press.intent, 'Press Enter search');
    expect(press.response, isEmpty);
  });
  test('drive text submission retains its requested intent', () {
    final submit = project(
      'drive_preview',
      {'action': 'type', 'ref': 'search', 'text': 'privacy', 'submit': true},
      {'acted': 'typed into Search and submitted'},
    );
    expect(submit.intent, 'Enter text search and submit');
    expect(submit.response.single.copyable, isFalse);
  });
  test('drive scroll preserves amount and no-scroll receipt', () {
    final scroll = project(
      'drive_preview',
      {'action': 'scroll', 'amount': -600},
      {'acted': 'scrolled the page', 'note': 'The page has nothing to scroll.'},
    );
    expect(scroll.intent, 'Scroll -600 px');
    expect(scroll.response.last.text, 'The page has nothing to scroll.');
  });

  test('drive probable navigation keeps backend uncertainty', () {
    final navigating = project(
      'drive_preview',
      {'action': 'click', 'ref': 'settings'},
      {
        'success': true,
        'acted': 'clicked Settings',
        'note': 'The page stopped answering; it is probably navigating.',
      },
    );
    expect(navigating.resourceTarget, isNull);
    expect(navigating.response.last.text, contains('probably navigating'));
  });
  test(
    'drive interrupted typing keeps the exact authored input and partial failure',
    () {
      final interrupted = project(
        'drive_preview',
        {'action': 'type', 'ref': 'notes', 'text': 'Complete note'},
        {
          'success': false,
          'error':
              'Typing stopped after 5 of 13 characters because the action was interrupted.',
        },
      );
      expect(interrupted.request.single.copyText, 'Complete note');
      expect(interrupted.receiptState, ToolReceiptState.error);
      expect(interrupted.response.single.text, contains('5 of 13'));
      expect(interrupted.response.single.copyable, isFalse);
    },
  );

  test(
    'unsupported historical browser IDs do not gain current tool effects',
    () {
      for (final name in ['browser_fill', 'browser_take_screenshot']) {
        final details = project(
          name,
          {'ref': '@e1', 'text': 'Mira'},
          {'error': 'Unknown tool: $name'},
        );
        expect(details.request, isEmpty);
        expect(details.response.single.text, 'Unknown tool: $name');
        expect(details.receiptState, ToolReceiptState.error);
        expect(details.images, isEmpty);
      }
    },
  );
}
