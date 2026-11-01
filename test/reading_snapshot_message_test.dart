import 'dart:convert';
import 'package:wing/core/models/composer_reference.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/answer_versions.dart';
import 'package:wing/core/models/reading_snapshot_message.dart';
import 'package:wing/core/models/transcript_notice.dart';
import 'package:wing/core/models/transcript_message.dart';
import 'package:wing/core/models/transcript_timeline.dart';
import 'package:wing/core/models/user_message_content.dart';

void main() {
  Map<String, dynamic> roundtrip(Map<String, dynamic> source) =>
      Map<String, dynamic>.from(
        jsonDecode(
              jsonEncode(
                projectReadingSnapshotMessage(
                  captureReadingSnapshotMessage(source),
                ),
              ),
            )
            as Map,
      );

  test('received review identity survives as a passive reading receipt', () {
    final saved = roundtrip({
      'id': 'review-runtime:12',
      'role': 'system',
      'content': 'review:Memory updated',
      '_review_notice': 'runtime:12',
      'timestamp': 101.25,
      'prompts': [
        {
          'kind': 'approval',
          'prompt_id': 'never-restore',
          'execution_generation': 0,
        },
      ],
    });
    expect(saved['_review_notice'], 'runtime:12');
    expect(saved['timestamp'], 101.25);
    expect(saved.containsKey('prompts'), isFalse);
  });

  test('a user message cannot claim a trusted review receipt', () {
    expect(
      roundtrip({
        'role': 'user',
        'content': 'review:Quoted example',
        '_review_notice': 'untrusted',
      }).containsKey('_review_notice'),
      isFalse,
    );
  });

  test(
    'large prepared context retains authored text, images and reference identity',
    () {
      const ref = ComposerReference(
        kind: ComposerReferenceKind.file,
        token: '@file:/work/note.md',
        target: '/work/note.md',
      );
      final prepared = PreparedComposerMessage(
        message: 'Read ${ref.token}',
        context: 'source' * 20000,
        references: const [ref],
      );
      final saved = roundtrip({
        'role': 'user',
        'id': 19,
        'content': '${prepared.wireText}\n@image:/cache/photo.png',
      });
      expect(
        answerMessageDisplayText(saved),
        'Read ${ref.token}\n@image:/cache/photo.png',
      );
      expect(jsonEncode(saved).length, lessThan(4096));
      expect(
        PreparedComposerMessage.fromContent(
          saved['content'],
        )!.references.single.target,
        ref.target,
      );
    },
  );

  test('prepared structured reading retains native image parts', () {
    final prepared = PreparedComposerMessage(
      message: 'Read @hermes',
      context: 'context' * 10000,
    );
    final saved = roundtrip({
      'role': 'user',
      'content': [
        {'type': 'text', 'text': prepared.wireText},
        {
          'type': 'image_url',
          'image_url': {'url': '/cache/photo.png'},
        },
      ],
    });
    final display = UserMessageContent.fromMessage(saved);
    expect(display.text, 'Read @hermes');
    expect(display.attachments.single.target, '/cache/photo.png');
    expect(jsonEncode(saved).length, lessThan(4096));
  });

  test(
    'prepared references retain native vision hints through reading cache',
    () {
      const reference = ComposerReference(
        kind: ComposerReferenceKind.file,
        token: '@file:/work/note.md',
        target: '/work/note.md',
      );
      const authored = 'Read @file:/work/note.md and compare these images';
      const paths = ['/cache/first image.png', '/cache/second.png'];
      final suffix = [
        '',
        '',
        ...paths.map((path) => '[Image attached at: $path]'),
        ...List.filled(paths.length, '[screenshot]'),
        '<memory-context>Model-only memory</memory-context>',
      ].join('\n');
      final prepared = PreparedComposerMessage(
        message: authored,
        context: 'large reference context' * 10000,
        references: const [reference],
      );
      final wire = '${prepared.wireText}$suffix';
      expect(PreparedComposerMessage.parse(wire)!.imageReferences, suffix);
      for (final content in <Object>[
        wire,
        [
          {'type': 'text', 'text': wire},
          for (var i = 0; i < paths.length; i++)
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,image$i'},
            },
        ],
      ]) {
        final row = <String, dynamic>{'role': 'user', 'content': content};
        final saved = roundtrip(row);
        for (final value in [row, saved]) {
          final message = TranscriptMessage.fromRow(value);
          expect(message.text, authored);
          expect(message.attachments.map((image) => image.target), paths);
          expect(message.attachments.every((image) => image.isImage), isTrue);
          expect(message.copyText, startsWith('$authored$suffix'));
          expect(
            message.copyText,
            isNot(contains(PreparedComposerMessage.header)),
          );
          expect(
            PreparedComposerMessage.fromContent(
              value['content'],
            )!.references.single.target,
            reference.target,
          );
        }
        expect(jsonEncode(saved).length, lessThan(4096));
        expect(
          PreparedComposerMessage.fromContent(saved['content'])!.context,
          '',
        );
      }
    },
  );

  test('prepared native hint without image evidence remains literal text', () {
    const literal = '\n\n[Image attached at: /cache/example.png]';
    final prepared = PreparedComposerMessage(
      message: 'Explain this',
      context: '',
    );
    for (final row in [
      {'role': 'user', 'content': '${prepared.wireText}$literal'},
      roundtrip({'role': 'user', 'content': '${prepared.wireText}$literal'}),
    ]) {
      final message = TranscriptMessage.fromRow(row);
      expect(message.text, 'Explain this$literal');
      expect(message.attachments, isEmpty);
    }
  });
  test(
    'tool reading facts survive without timestamps or execution authority',
    () {
      final saved = roundtrip({
        'id': 21,
        'role': 'tool',
        'content': 'Rental terms',
        'tool_call_id': 'measured',
        'tool_name': 'browser_exec',
        'duration_s': 1.25,
        'args': {'code': 'open("https://example.org/rentals")'},
        'labels': [
          {
            'text': 'Open rentals',
            'name': 'browser_exec',
            'preview': 'example.org/rentals',
            'credentials': 'excluded',
          },
        ],
        'started_at': 10,
        'phase': 'running',
        'runtime_id': 'excluded',
      });
      expect(saved['duration_s'], 1.25);
      expect(saved['tool_call_id'], 'measured');
      expect(saved['tool_name'], 'browser_exec');
      expect(jsonDecode(saved['args']), {
        'code': 'open("https://example.org/rentals")',
      });
      expect(jsonEncode(saved), isNot(contains('excluded')));
      expect(saved.containsKey('started_at'), isFalse);
      expect(saved.containsKey('phase'), isFalse);
    },
  );
  for (final seconds in [-1, double.nan, double.infinity, '1.25']) {
    test('tool duration rejects $seconds (${seconds.runtimeType})', () {
      expect(
        roundtrip({
          'role': 'tool',
          'duration_s': seconds,
        }).containsKey('duration_s'),
        isFalse,
      );
    });
  }
  test('assistant rows cannot claim tool duration', () {
    expect(
      roundtrip({
        'role': 'assistant',
        'duration_s': 1.25,
        'tool_call_id': 'bad',
      }).containsKey('duration_s'),
      isFalse,
    );
  });

  test('hidden and synthetic rows remain hidden without runtime fields', () {
    for (final marker in [
      {'display_kind': 'hidden'},
      {'_todo_snapshot_synthetic': true},
    ]) {
      final saved = roundtrip({
        'row_id': 3,
        'role': 'user',
        'content': 'Internal context',
        ...marker,
        'session_id': 'live-runtime',
        'prompts': [
          {
            'kind': 'approval',
            'prompt_id': 'not-reading',
            'execution_generation': 0,
          },
        ],
        'metadata': {'unrelated': 'excluded'},
      });
      expect(isHiddenAnswerMessage(saved), isTrue);
      expect(answerMessageId(saved), 3);
      expect(saved.keys, isNot(contains('session_id')));
      expect(saved.keys, isNot(contains('prompts')));
      expect(saved.keys, isNot(contains('metadata')));
    }
  });

  test('saved steering retains its clean text and replay classification', () {
    final saved = roundtrip({
      'id': 4,
      'role': 'user',
      'content': 'Model-facing context',
      'display_kind': 'steer',
      'display_content': 'Keep searching',
    });
    expect(steeringMessageText(saved), 'Keep searching');
    expect(answerMessageDisplayText(saved), 'Keep searching');
    expect(isAnswerPrompt(saved), isFalse);
  });

  test(
    'typed display metadata survives cache restore and notification selection',
    () {
      for (final cacheRoundtrip in [false, true]) {
        Map<String, dynamic> metadata(Map<String, dynamic> value) =>
            cacheRoundtrip
            ? Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map)
            : value;
        final hidden = roundtrip({
          'id': 8,
          'role': 'assistant',
          'content': 'Internal model carrier',
          'display_metadata': metadata({
            'model_only': true,
            'runtime_secret': 'excluded',
          }),
        });
        final visible = roundtrip({
          'id': 7,
          'role': 'assistant',
          'content': 'Actual answer',
        });
        expect(
          TranscriptMessage.fromRow(hidden).kind,
          TranscriptMessageKind.hidden,
        );
        expect(hidden['id'], 8);
        expect(hidden['content'], 'Internal model carrier');
        expect(hidden['display_metadata'], {'model_only': true});
        expect(
          TranscriptTimeline.notificationAnswerPresentation([
            visible,
            hidden,
          ], presentationId: (row) => row['id']!),
          7,
        );
        expect(
          TranscriptTimeline.notificationAnswerPresentation(
            [visible, hidden],
            presentationId: (row) => row['id']!,
            messageId: 8,
          ),
          isNull,
        );

        for (final kind in ['async_delegation_complete', 'process_complete']) {
          final saved = roundtrip({
            'id': 9,
            'role': 'user',
            'content': kind == 'process_complete'
                ? '[IMPORTANT: Background process proc_example exited (exit code 1).\nCommand: false\nOutput:\nReal error]'
                : '[ASYNC DELEGATION COMPLETE — task]\nPrivate preamble\n--- RESULT ---\nReal result',
            'display_kind': kind,
            'display_metadata': metadata({
              'display_text': 'Producer-selected failure title',
              'task_count': 1,
              'runtime_secret': 'excluded',
            }),
          });
          final display = TranscriptMessage.fromRow(saved);
          expect(display.kind, TranscriptMessageKind.notice);
          expect(display.text, 'Producer-selected failure title');
          expect(
            display.noticeResult,
            contains(kind == 'process_complete' ? 'Real error' : 'Real result'),
          );
          expect(display.noticeResult, isNot(contains('Private preamble')));
          expect(isAnswerPrompt(saved), isFalse);
          expect(jsonEncode(saved), isNot(contains('excluded')));
        }
      }
    },
  );

  test('malformed markers cannot hide ordinary user or assistant content', () {
    for (final role in ['user', 'assistant']) {
      for (final metadata in [
        '{invalid',
        '[]',
        '{"model_only":true}',
        '{"display_text":"Legacy string has no authority"}',
        {'model_only': 'true'},
        {'model_only': 1},
        {'unknown': true},
      ]) {
        final saved = roundtrip({
          'role': role,
          'content': 'Actual words',
          'display_kind': 'unknown_kind',
          'display_metadata': metadata,
        });
        expect(isHiddenAnswerMessage(saved), isFalse);
        expect(
          TranscriptMessage.fromRow(saved).kind,
          TranscriptMessageKind.dialogue,
        );
      }
    }
  });

  test('notice kind, count and result survive current stock map metadata', () {
    for (final metadata in [
      {'task_count': 2, 'unrelated': 'excluded'},
    ]) {
      final saved = roundtrip({
        'id': 5,
        'role': 'user',
        'display_kind': 'async_delegation_complete',
        'display_metadata': metadata,
        'content':
            '[ASYNC DELEGATION COMPLETE — deleg_example]\n'
            'Model-facing preamble\n--- RESULT ---\n'
            'Finished result\n'
            'Full live transcript (complete tool/assistant trace): /server/log\n',
      });
      expect(transcriptNoticeText(saved), '2 background agents finished');
      expect(transcriptNoticeResult(saved), 'Finished result');
      expect(saved['display_metadata'], {'task_count': 2});
      expect(isHiddenAnswerMessage(saved), isFalse);
      expect(isAnswerPrompt(saved), isFalse);
    }
    for (final kind in [
      'model_switch',
      'auto_continue',
      'personality_switch',
    ]) {
      final source = {'role': 'user', 'content': '', 'display_kind': kind};
      expect(
        transcriptNoticeText(roundtrip(source)),
        transcriptNoticeText(source),
      );
    }
  });

  test('structured text and image references keep their display meaning', () {
    final source = <String, dynamic>{
      'id': 'local-row',
      'role': 'user',
      'timestamp': 42.5,
      'content': [
        {'type': 'text', 'text': 'Caption', 'credentials': 'excluded'},
        {
          'type': 'image_url',
          'name': 'photo.jpg',
          'image_url': {'url': '/server/photo.jpg', 'headers': 'excluded'},
        },
        {'type': 'input_audio', 'raw_audio': 'excluded'},
      ],
      'display_content': [
        {'type': 'text', 'text': 'Visible caption'},
      ],
    };
    final saved = roundtrip(source);
    final display = UserMessageContent.fromMessage(saved);
    expect(display.text, 'Visible caption');
    expect(display.attachments.single.name, 'photo.jpg');
    expect(display.attachments.single.target, '/server/photo.jpg');
    expect(jsonEncode(saved), isNot(contains('excluded')));
    expect(saved['timestamp'], 42.5);
    expect(source['content'][0]['credentials'], 'excluded');
  });

  test('malformed or nested metadata cannot escape the typed projection', () {
    final malformed = projectReadingSnapshotMessage({
      'id': {'nested': 'excluded'},
      'role': {'nested': 'excluded'},
      'content': {
        'arbitrary': {'nested': 'excluded'},
      },
      'display_content': [
        [
          {'text': 'excluded'},
        ],
      ],
      'timestamp': double.infinity,
      'hidden': 'true',
      'display_kind': 'async_delegation_complete',
      'display_metadata': {'task_count': 2.5, 'nested': 'excluded'},
      'approval': {'request_id': 'excluded'},
    });
    expect(malformed, {
      'display_kind': 'async_delegation_complete',
      'display_content': [],
    });
  });
  for (final count in [0, -1, double.nan, double.infinity, 1e50]) {
    test('invalid task count $count cannot survive projection', () {
      final projected = projectReadingSnapshotMessage({
        'display_kind': 'async_delegation_complete',
        'display_metadata': {'task_count': count},
      });
      expect(projected.containsKey('display_metadata'), isFalse);
    });
  }
  test('oversized content-part list cannot survive projection', () {
    final manyParts = projectReadingSnapshotMessage({
      'content': List.filled(257, {'type': 'text', 'text': 'part'}),
    });
    expect(manyParts.containsKey('content'), isFalse);
  });

  test('optimistic attachment-only rows retain typed passive cards', () {
    for (final attachment in const [
      UserMessageAttachment(
        name: 'Shared photo.jpg',
        target: '/server/photo.jpg',
        isImage: true,
      ),
      UserMessageAttachment(
        name: 'Original report.pdf',
        target: '@file:"/server/uploaded-report.pdf"',
        isImage: false,
      ),
    ]) {
      final encoded = roundtrip({
        'role': 'user',
        'content': '',
        'submitted_attachments': [attachment],
      });
      final restored = {
        ...encoded,
        'submitted_attachments': readingSnapshotAttachments(
          encoded['submitted_attachments'],
        ),
      };
      final display = UserMessageContent.fromMessage(restored);
      expect(display.text, isEmpty);
      expect(display.attachments.single.name, attachment.name);
      expect(display.attachments.single.target, attachment.target);
      expect(display.attachments.single.isImage, attachment.isImage);
      expect((encoded['submitted_attachments'] as List).single, {
        'name': attachment.name,
        'target': attachment.target,
        'is_image': attachment.isImage,
      });
    }
  });

  test('attachment cache accepts only bounded names and references', () {
    final encoded = roundtrip({
      'role': 'user',
      'submitted_attachments': [
        {
          'name': 'report.pdf',
          'target': '/server/report.pdf',
          'is_image': false,
          'cachedPath': 'excluded',
          'attachedSessionId': 'excluded',
          'content_base64': 'excluded',
          'status': 'attached',
        },
        {'name': 'bad', 'target': '/bad', 'is_image': 'true'},
        {
          'name': 'bytes',
          'target': 'data:image/png;base64,excluded',
          'is_image': true,
        },
        {
          'name': 'bytes',
          'target': ' DATA:image/png;base64,excluded',
          'is_image': true,
        },
        {'name': 'x' * 1025, 'target': '/bad', 'is_image': false},
        {'name': 'bad', 'target': 'x' * 8193, 'is_image': false},
      ],
    });
    expect(encoded['submitted_attachments'], [
      {'name': 'report.pdf', 'target': '/server/report.pdf', 'is_image': false},
    ]);
    expect(jsonEncode(encoded), isNot(contains('excluded')));
    expect(
      readingSnapshotAttachments(
        List.filled(
          17,
          const UserMessageAttachment(
            name: 'file',
            target: '/server/file',
            isImage: false,
          ),
        ),
      ),
      hasLength(16),
    );
  });
}
