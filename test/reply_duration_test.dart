import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/transcript_timeline.dart';
import 'package:wing/core/theme/profile_workspace_theme.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/profile_tool_activity.dart';

const _capture = bool.fromEnvironment('STUDIO_REVIEW');
const _frame = ValueKey('reply-duration-frame');
const _explanation =
    'Approximate reply time: final reply timestamp minus the triggering message '
    'timestamp, both from Hermes';

Map<String, dynamic> _row(int id, String role, double? timestamp) => {
  'id': id,
  'role': role,
  'content': role == 'tool' ? 'Completed' : 'Message $id',
  'timestamp': ?timestamp,
};

TranscriptTimeline _timeline(List<Map<String, dynamic>> rows, {int? live}) =>
    TranscriptTimeline.project(
      rows,
      presentationId: (row) => row['id'] ?? row,
      liveMessageIndex: live,
    );

void main() {
  test(
    'live execution uses the current prompt and positioned answer timestamps',
    () {
      final timeline = _timeline([
        _row(1, 'user', 1000),
        _row(2, 'assistant', 1010),
        _row(3, 'user', 2000.125),
        {..._row(4, 'user', 2005), 'display_kind': 'steer'},
        _row(5, 'tool', 2010),
        _row(6, 'assistant', 2040.625),
      ]);
      final timing = timeline.executionTimingBefore(6);
      expect(
        timing.end!.difference(timing.start!),
        const Duration(milliseconds: 40500),
      );
      expect(timeline.executionTimingBefore(null).start, timing.start);
      expect(timeline.executionTimingBefore(999), (start: null, end: null));
      final missing = _timeline([
        _row(1, 'user', 1000),
        _row(2, 'user', null),
        _row(3, 'tool', 2000),
      ]);
      expect(missing.executionTimingBefore(null).start, isNull);
      final process = _timeline([
        _row(1, 'user', 1000),
        {..._row(2, 'user', 2000), 'display_kind': 'process_complete'},
        _row(3, 'tool', 2010),
      ]);
      expect(
        process.executionTimingBefore(null).start,
        isNull,
        reason: 'An internal trigger cannot borrow an older human prompt.',
      );
    },
  );

  test(
    'bot delivery starts its own reply interval after an older human turn',
    () {
      final timeline = _timeline([
        _row(1, 'user', 1000),
        _row(2, 'assistant', 1010),
        {
          ..._row(3, 'user', 103680),
          'content': 'Message from 🤖 Pace (@pace): Please create the issue.',
        },
        _row(4, 'assistant', 103690),
        _row(5, 'tool', 103700),
        _row(6, 'assistant', 103777),
      ]);
      expect(
        timeline.sections.lastWhere((s) => s.isActivity).replyDuration,
        const Duration(seconds: 97),
      );
    },
  );

  setUpAll(() async {
    if (!_capture) return;
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'Ahem': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            Future.value(
              ByteData.sublistView(File(entry.value).readAsBytesSync()),
            ),
          ))
          .load();
    }
  });

  test(
    'each bot delivery resets time and a missing stamp never borrows a prompt',
    () {
      for (final stamp in [2000.0, null]) {
        final timeline = _timeline([
          _row(1, 'user', 1000),
          _row(2, 'assistant', 1010),
          {
            ..._row(3, 'user', stamp),
            'content': 'Message from 🤖 Pace (@pace): First request',
          },
          _row(4, 'tool', 2010),
          _row(5, 'assistant', 2020),
          {
            ..._row(6, 'user', 3000),
            'content': 'Message from 🤖 Default (@hermes): Second request',
          },
          _row(7, 'tool', 3010),
          _row(8, 'assistant', 3030),
        ]);
        expect(
          timeline.sections
              .where((s) => s.isActivity)
              .map((s) => s.replyDuration),
          [
            stamp == null ? null : const Duration(seconds: 20),
            const Duration(seconds: 30),
          ],
        );
        expect(timeline.entries[4].branchAnswer, isFalse);
        expect(timeline.entries[7].branchAnswer, isFalse);
      }
    },
  );

  test('each final reply uses its own original sent message', () {
    final timeline = _timeline([
      _row(1, 'user', 1000.125),
      {
        ..._row(2, 'assistant', 1020),
        'tool_calls': [
          {'id': 'call-1'},
        ],
      },
      {..._row(3, 'tool', 1030), 'duration_s': 9000},
      _row(4, 'assistant', 1040), // Interim commentary before more work.
      _row(5, 'tool', 1050),
      _row(6, 'assistant', 1084.125),
      _row(7, 'user', 2000),
      _row(8, 'tool', 2050),
      _row(9, 'assistant', 2120),
    ]);
    expect(
      timeline.sections.where((s) => s.isActivity).map((s) => s.replyDuration),
      [null, const Duration(seconds: 84), const Duration(minutes: 2)],
    );
    expect(
      timeline.sections.where((s) => s.isActivity).map((s) => s.toolCount),
      [1, 1, 1],
    );
  });

  test('steering and hidden generated prompts do not reset the sent time', () {
    final timeline = _timeline([
      _row(1, 'user', 1000),
      _row(2, 'tool', 1020),
      {..._row(3, 'user', 1030), 'display_kind': 'steer'},
      {..._row(4, 'user', 1040), 'display_kind': 'hidden'},
      _row(5, 'tool', 1050),
      _row(6, 'assistant', 1084),
    ]);
    expect(
      timeline.sections.lastWhere((s) => s.isActivity).replyDuration,
      const Duration(seconds: 84),
    );
  });

  test('only saved backend timestamps contribute to the interval', () {
    final cases = <List<Map<String, dynamic>>>[
      [
        _row(1, 'user', null),
        _row(2, 'tool', 1030),
        _row(3, 'assistant', 1084),
      ],
      [
        _row(1, 'user', 1000),
        _row(2, 'tool', 1030),
        _row(3, 'assistant', null),
      ],
      [_row(2, 'tool', 1030), _row(3, 'assistant', 1084)],
      [
        {'role': 'user', 'content': 'Not saved yet', 'timestamp': 1000},
        _row(2, 'tool', 1030),
        _row(3, 'assistant', 1084),
      ],
      [
        _row(1, 'user', 1000),
        _row(2, 'tool', 1030),
        {'role': 'assistant', 'content': 'Local completion', 'timestamp': 1084},
      ],
      [
        _row(1, 'user', 1000),
        _row(2, 'tool', 1030),
        {
          ..._row(3, 'assistant', 1084),
          'tool_calls': [
            {'id': 'call-2'},
          ],
        },
      ],
      [_row(1, 'user', 1000), _row(2, 'tool', 1030)],
      for (final timestamp in [
        double.nan,
        double.infinity,
        -1.0,
        0.0,
        1e15,
        999.0,
      ])
        [
          _row(1, 'user', 1000),
          _row(2, 'tool', 1030),
          _row(3, 'assistant', timestamp),
        ],
    ];
    for (final rows in cases) {
      expect(
        _timeline(
          rows,
        ).sections.where((s) => s.isActivity).map((s) => s.replyDuration),
        everyElement(isNull),
        reason: '$rows',
      );
    }
    final streaming = _timeline([
      _row(1, 'user', 1000),
      _row(2, 'tool', 1030),
      _row(3, 'assistant', 1084),
    ], live: 2);
    expect(
      streaming.sections.firstWhere((s) => s.isActivity).replyDuration,
      isNull,
    );
  });

  test(
    'unknown timestamps never borrow a preceding turn or an interim end',
    () {
      final timeline = _timeline([
        _row(1, 'user', 1000),
        _row(2, 'tool', 1010),
        _row(3, 'assistant', 1020),
        _row(4, 'user', null),
        _row(5, 'tool', 1030),
        _row(6, 'assistant', 1084),
        _row(7, 'user', 1100),
        _row(8, 'tool', 1110),
        _row(9, 'assistant', 1120),
        _row(10, 'tool', 1130),
      ]);
      expect(
        timeline.sections
            .where((s) => s.isActivity)
            .map((s) => s.replyDuration),
        [const Duration(seconds: 20), null, null, null],
      );
    },
  );

  test('zero and fractional intervals are valid and keep exact precision', () {
    for (final seconds in [0.0, 0.125, 84.125]) {
      final timeline = _timeline([
        _row(1, 'user', 1000),
        _row(2, 'tool', 1000),
        _row(3, 'assistant', 1000 + seconds),
      ]);
      expect(
        timeline.sections.firstWhere((s) => s.isActivity).replyDuration,
        Duration(microseconds: (seconds * 1000000).round()),
      );
    }
  });

  test(
    'Find keeps the full interval when the prompt is outside its neighborhood',
    () {
      final timeline = _timeline([
        _row(1, 'user', 1000),
        for (var id = 2; id <= 30; id++) _row(id, 'tool', 1000.0 + id),
        _row(31, 'assistant', 1084),
      ]);
      final nearby = timeline.nearby(31)!;
      expect(nearby.entries.any((e) => e.id == 1), isFalse);
      expect(
        nearby.sections.firstWhere((s) => s.isActivity).replyDuration,
        const Duration(seconds: 84),
      );
    },
  );

  testWidgets('saved timestamp interval appears beside the tool count', (
    tester,
  ) async {
    final timeline = _timeline([
      _row(1, 'user', 1791616320.25),
      _row(2, 'tool', 1791616350),
      _row(3, 'assistant', 1791616404.25),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileToolActivitySection(
            section: timeline.sections.firstWhere((s) => s.isActivity),
          ),
        ),
      ),
    );
    expect(find.text('Activity · 1 tool'), findsOneWidget);
    expect(find.text('· 1m 24s'), findsOneWidget);
    expect(find.byTooltip(_explanation), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'reply time wraps and retains actions in ${brightness.name} at $scale',
        (tester) async {
          final width = scale == 1 ? 390.0 : 320.0;
          await tester.binding.setSurfaceSize(Size(width, 680));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final timeline = _timeline([
            _row(1, 'user', 1000),
            for (var id = 2; id <= 12; id++) _row(id, 'tool', 1000.0 + id),
            {..._row(13, 'system', 1050), 'content': 'review: Checked changes'},
            _row(14, 'assistant', 1084),
          ]);
          var copies = 0;
          await tester.pumpWidget(
            RepaintBoundary(
              key: _frame,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: profileWorkspaceTheme(wingTheme(brightness)),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 4, 16),
                    child: ProfileToolActivitySection(
                      section: timeline.sections.firstWhere(
                        (s) => s.isActivity,
                      ),
                      trailing: IconButton(
                        tooltip: 'Copy reply',
                        onPressed: () => copies++,
                        icon: const Icon(Icons.copy_outlined),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final count = find.text('Activity · 11 tools');
          final metadata = find.text('· 1m 24s · 1 review');
          expect(count, findsOneWidget);
          expect(metadata, findsOneWidget);
          expect(
            tester.getRect(metadata).right,
            lessThanOrEqualTo(
              tester.getRect(find.byTooltip('Copy reply')).left,
            ),
          );
          expect(tester.getRect(metadata).left, greaterThanOrEqualTo(16));
          expect(find.byTooltip(_explanation), findsOneWidget);
          expect(find.byType(ProfileToolActivity), findsNothing); // Still lazy.
          await tester.tap(find.byTooltip('Copy reply'));
          expect(copies, 1);
          expect(tester.takeException(), isNull);
          if (_capture) {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(_frame),
            );
            await tester.runAsync(() async {
              final image = await boundary.toImage(pixelRatio: 1);
              final png = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final directory = Directory('build/reply-duration-review')
                ..createSync(recursive: true);
              File(
                '${directory.path}/${brightness.name}-${scale == 1 ? 'normal' : 'large'}.png',
              ).writeAsBytesSync(png!.buffer.asUint8List());
              image.dispose();
            });
          }
        },
      );
    }
  }
}
