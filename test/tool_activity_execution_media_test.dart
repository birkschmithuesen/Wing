import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/presentation/tool_activity_details.dart';

ToolActivityDetails receipt(
  String name,
  Map<String, Object?> args,
  Object? result,
) => ToolActivityDetails.project(name: name, input: args, output: result);

const imageBytes =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

void main() {
  test('terminal informational exit is a neutral completion', () {
    final noMatches = receipt(
      'terminal',
      {'command': 'rg missing src'},
      {
        'output': '',
        'exit_code': 1,
        'exit_code_meaning': 'No matches found (not an error)',
      },
    );
    expect(noMatches.exitCode, 1);
    expect(noMatches.receiptState, ToolReceiptState.completed);
    expect(noMatches.receiptStatus, 'Completed');
    expect(noMatches.response.single.copyable, isFalse);
  });

  test('terminal signal exit is not completion', () {
    final signal = receipt(
      'terminal',
      {'command': 'python3 worker.py'},
      {
        'output': '',
        'exit_code': 137,
        'exit_code_meaning':
            'Exit code 137 usually means the command was terminated by signal 9: SIGKILL',
      },
    );
    expect(signal.receiptState, ToolReceiptState.error);
    expect(signal.receiptStatus, 'Exited with code 137');
    expect(signal.response.single.text, contains('usually'));
  });

  test('terminal launch reports started rather than completed', () {
    const command = '  python3 worker.py\n';
    final launched = receipt(
      'terminal',
      {'command': command, 'background': true},
      {
        'output': 'Background process started',
        'exit_code': 0,
        'session_id': 'process-id',
        'watch_patterns': ['Ready'],
        'notify_on_complete': true,
        'heartbeat_seconds': 60,
      },
    );
    expect(launched.request.single.copyText, command);
    expect(launched.receiptStatus, 'Started in background');
    expect(launched.exitCode, isNull);
    expect(launched.response, isEmpty);
    expect(launched.metadata, contains('Completion notification armed'));
  });

  test('terminal handoff preserves partial output and continuing status', () {
    const command = '  python3 worker.py\n';
    final yielded = receipt(
      'terminal',
      {'command': command},
      {
        'output': 'Last received partial output.\n',
        'status': 'yielded_to_background',
        'session_id': 'process-id',
        'note': 'Command yielded to the background; do not run it again.',
      },
    );
    expect(yielded.receiptStatus, 'Continuing in background');
    expect(yielded.response.first.copyText, 'Last received partial output.\n');
    expect(yielded.response.last.copyable, isFalse);
  });

  test('terminal approval never pretends empty console was executed', () {
    final detail = receipt('terminal', {}, {
      'command': 'remove selected files',
      'output': '',
      'status': 'pending_approval',
      'description': 'Command requires approval.',
      'error': '',
    });
    expect(detail.request.single.text, 'remove selected files');
    expect(detail.receiptStatus, 'Awaiting approval');
    expect(detail.metadata, isEmpty);
    expect(detail.response.single.copyable, isFalse);
  });

  test(
    'terminal spill scope and reported verification facts preserve actual evidence',
    () {
      const output = 'First\n[... middle omitted ...]\nLast';
      final detail = receipt(
        'terminal',
        {'command': 'build'},
        {
          'output': output,
          'exit_code': 0,
          'full_output_path': '/cache/full-output.txt',
          'truncation_note': 'Only the first and last output were captured.',
          'verification_evidence': {
            'status': 'passed',
            'kind': 'tests',
            'scope': 'targeted',
            'canonical_command': 'build',
          },
        },
      );
      expect(detail.response.first.copyText, output);
      expect(detail.response.first.resourceTarget, '/cache/full-output.txt');
      expect(detail.response.last.copyable, isFalse);
      expect(detail.metadata, [
        'Reported check: passed',
        'Check kind: tests',
        'Check scope: targeted',
      ]);
    },
  );

  test(
    'code helper failure qualifies script success and literal console stays exact',
    () {
      const code = 'print("# looks like Markdown")\n';
      const output = '# looks like Markdown\n';
      final detail = receipt(
        'execute_code',
        {'code': code},
        {
          'status': 'success',
          'output': output,
          'exit_code': 0,
          'tool_errors': [
            {'tool': 'read_file', 'error': 'File missing.'},
          ],
          'kernel': {'state_reset': true, 'ended': true},
        },
      );
      expect(detail.request.single.copyText, code);
      expect(detail.response.first.copyText, output);
      expect(detail.response.first.format, ToolDetailFormat.source);
      expect(detail.response.first.markdown, isFalse);
      expect(detail.response.last.text, 'File missing.');
      expect(detail.receiptState, ToolReceiptState.warning);
      expect(detail.metadata, ['Kernel ended', 'Kernel state reset']);
    },
  );

  test(
    'code timeout preserves specific outcome and does not repeat embedded traceback',
    () {
      const error = 'Cell timed out; kernel state was lost.';
      final timeout = receipt(
        'execute_code',
        {'code': 'slow()'},
        {
          'status': 'timeout',
          'output': 'Partial output\n$error',
          'error': error,
          'kernel': {'state_lost': true, 'note': error},
        },
      );
      expect(timeout.receiptStatus, 'Timed out');
      expect(timeout.receiptState, ToolReceiptState.error);
      expect(timeout.response.where((b) => b.label == 'Error'), isEmpty);
    },
  );

  test('code truncation preserves spill path and reported byte counts', () {
    final truncated = receipt(
      'execute_code',
      {'code': 'print(rows)'},
      {
        'status': 'success',
        'output': 'First\n[... omitted ...]\nLast',
        'stdout_truncated': true,
        'stdout_bytes_captured': 50000,
        'stdout_bytes_omitted': 230000,
        'stdout_spill_path': '/cache/stdout.txt',
      },
    );
    expect(truncated.response.single.resourceTarget, '/cache/stdout.txt');
    expect(truncated.metadata, [
      'Partial output returned',
      'Captured stdout bytes: 50000',
      'Omitted stdout bytes: 230000',
    ]);
  });

  test(
    'browser native envelope and saved content list recover one console receipt',
    () {
      const output =
          'Title: Actual page\nScreenshot saved: /workspace/page.png\n';
      final ordinary = {
        'success': true,
        'exit_code': 0,
        'output': output,
        'screenshot_path': '/workspace/page.png',
        'workspace': '/workspace/browser',
      };
      final text = jsonEncode(ordinary);
      final content = [
        {
          'type': 'text',
          'text':
              '$text\n\nThe screenshot from this call is attached — inspect it with your native vision.',
        },
        {
          'type': 'image_url',
          'image_url': {'url': imageBytes},
        },
      ];
      for (final result in [
        {'_multimodal': true, 'text_summary': text, 'content': content},
        content,
      ]) {
        final detail = receipt('browser_exec', {
          'code': 'capture_screenshot()',
        }, result);
        expect(detail.response.single.copyText, output);
        expect(detail.images.single.target, '/workspace/page.png');
        expect(detail.metadata, ['Workspace: /workspace/browser']);
        expect(detail.response.single.format, ToolDetailFormat.source);
      }
    },
  );

  test(
    'browser stderr on success is diagnostics and retains server truncation',
    () {
      const stderr = 'Warning detail\n… (stderr truncated)';
      final detail = receipt(
        'browser_exec',
        {'code': 'print(page_info())'},
        {'success': true, 'exit_code': 0, 'output': '', 'stderr': stderr},
      );
      expect(detail.response.single.copyText, stderr);
      expect(detail.response.single.label, 'Diagnostics');
      expect(detail.receiptState, isNot(ToolReceiptState.error));
    },
  );

  test(
    'image generation presents actual artifacts and differing reported settings only',
    () {
      const prompt = '# Requested picture\nUse a red background.\n';
      final detail = receipt(
        'image_generate',
        {
          'prompt': prompt,
          'image_url': '/input/ref.png',
          'reference_image_urls': ['/input/ref.png', '/input/style.png'],
          'aspect_ratio': 'portrait',
          'upscale': true,
        },
        {
          'success': true,
          'image': '/output/result.png',
          'additional_images': ['/output/second.png', '/output/second.png'],
          'provider': 'provider',
          'model': 'model',
          'prompt': prompt,
          'pixel_size': '1024x1536',
          'requested_size': '1024x1536',
          'reported_size': '1024x1024',
          'quality': 'high',
          'input_image_count': 1,
          'n': 4,
          'upscaled': false,
          'notes': ['A reference could not be read.'],
        },
      );
      expect(detail.request.single.copyText, prompt);
      expect(detail.images.map((i) => i.target), [
        '/input/ref.png',
        '/input/style.png',
        '/output/result.png',
        '/output/second.png',
      ]);
      expect(detail.metadata, contains('Pixels: 1024x1536'));
      expect(detail.metadata, contains('Provider reported size: 1024x1024'));
      expect(detail.metadata, contains('Input images used: 1'));
      expect(detail.metadata, contains('Upscaling was not reported'));
      expect(detail.response.single.copyable, isFalse);
      expect(detail.response.any((b) => b.text == prompt), isFalse);
    },
  );

  test(
    'image hosted fallback and revised prompt have separate meaningful scopes',
    () {
      final detail = receipt(
        'image_generate',
        {'prompt': 'Requested prompt.'},
        {
          'success': true,
          'public_url': 'https://example.org/result.png',
          'public_url_expires_at': 'tomorrow',
          'revised_prompt': 'Expanded prompt.',
          'storage_notice': 'Artifact is hosted temporarily.',
        },
      );
      expect(detail.images.single.target, 'https://example.org/result.png');
      expect(
        detail.response.where((b) => b.copyable).single.copyText,
        'Expanded prompt.',
      );
      expect(detail.metadata, ['Public image expiry: tomorrow']);
      expect(detail.metadata, isNot(contains('No image returned')));
    },
  );

  test('native vision uses actual received crop and cannot invent analysis', () {
    const note = 'Crop offset x=10 y=20; coordinates map to the original.';
    final detail = receipt(
      'vision_analyze',
      {
        'image_url': '/input/original.png',
        'question': 'Where is the label?',
        'region': [10, 20, 100, 200],
      },
      {
        '_multimodal': true,
        'content': [
          {
            'type': 'text',
            'text':
                'Image loaded into your context — you can see it natively now.\n\nQuestion: Where is the label?\n\nNote: $note',
          },
          {
            'type': 'image_url',
            'image_url': {'url': imageBytes},
          },
        ],
        'meta': {'native_vision': true, 'image_url': '/input/original.png'},
      },
    );
    expect(detail.images.single.label, 'Received image');
    expect(detail.images.single.target, imageBytes);
    expect(
      detail.receiptStatus,
      isNull,
    ); // Ordinary completion stays neutral; nativeVision supplies quiet context.
    expect(detail.response.single.text, note);
    expect(detail.response.single.copyable, isFalse);
    expect(detail.response.any((b) => b.label == 'Analysis'), isFalse);
  });

  test(
    'native saved receipt without crop bytes labels actual source as source',
    () {
      final detail = receipt(
        'vision_analyze',
        {
          'image_url': '/input/original.png',
          'region': [10, 20, 100, 200],
          'question': 'What is shown?',
        },
        'Image attached natively for the main model (148.0 KB). Answer using built-in vision.',
      );
      expect(detail.images.single.label, 'Source image');
      expect(detail.images.single.target, '/input/original.png');
      expect(detail.response, isEmpty);
      expect(detail.nativeVision, isTrue);
    },
  );

  test(
    'failed native vision keeps the source without claiming native analysis',
    () {
      final failed = receipt(
        'vision_analyze',
        {'image_url': '/input/original.png'},
        {'success': false, 'error': 'Could not decode image.'},
      );
      expect(failed.images.single.label, 'Source image');
      expect(failed.receiptStatus, 'Failed');
      expect(failed.nativeVision, isFalse);
    },
  );

  test(
    'native question from receipt is recovered without a clipped meta resource',
    () {
      final detail = receipt('vision_analyze', {}, {
        '_multimodal': true,
        'content': [
          {
            'type': 'text',
            'text':
                'Image loaded into your context — you can see it natively now.\n\nQuestion: Exact received question.\n\nNote: Actual note.',
          },
          {
            'type': 'image_url',
            'image_url': {'url': imageBytes},
          },
        ],
        'meta': {'image_url': 'https://example.org/truncated...'},
      });
      expect(detail.images.single.target, imageBytes);
      expect(
        detail.response.where((b) => b.copyable).single.copyText,
        'Exact received question.',
      );
      expect(
        detail.response.any((b) => b.text.contains('truncated...')),
        isFalse,
      );
    },
  );

  test(
    'auxiliary vision separates supplied scale note from exact copied analysis',
    () {
      const scale = 'Coordinates are in the original image.';
      const exact = '[$scale] # Actual answer\nThe label is at the top.\n';
      final detail = receipt(
        'vision_analyze',
        {'question': 'Where?'},
        {'success': true, 'analysis': exact, 'scale_note': scale},
      );
      expect(detail.response.first.label, 'Analysis');
      expect(
        detail.response.first.text,
        '# Actual answer\nThe label is at the top.\n',
      );
      expect(detail.response.first.copyText, exact);
      expect(detail.response.last.copyable, isFalse);
    },
  );

  test('empty auxiliary vision result does not claim analysis', () {
    final empty = receipt(
      'vision_analyze',
      {'question': 'Where?'},
      {
        'success': true,
        'analysis':
            'There was a problem with the request and the image could not be analyzed.',
      },
    );
    expect(empty.response.single.label, 'Result');
    expect(empty.response.single.copyable, isFalse);
    expect(empty.receiptStatus, 'No analysis returned');
  });

  test('failed auxiliary vision treats supplied analysis as context', () {
    final failed = receipt(
      'vision_analyze',
      {'question': 'Where?'},
      {
        'success': false,
        'error': 'Provider unavailable.',
        'analysis': 'Configure a working provider.',
      },
    );
    expect(failed.response.first.label, 'Context');
    expect(failed.response.first.copyable, isFalse);
    expect(failed.response.any((b) => b.label == 'Analysis'), isFalse);
  });
}
