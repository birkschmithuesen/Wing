import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:share_plus/share_plus.dart';
import 'package:wing/core/services/platform_share.dart';
import 'package:wing/core/presentation/skill_document.dart';
import 'package:wing/core/services/skill_reader_session.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/activity/skill_document_viewer.dart';

const demo =
    '---\ndescription: Use when reviewing evidence.\nversion: 1.0\nauthor: Example\nlicense: MIT\n---\n# Review\n\n## First\nRead **original** evidence.\n\n## Second\nCheck the outcome.\n';
SkillReaderSession reader(
  SkillDocument document,
  Map? captured, {
  Future<void>? activityReady,
  bool failActivity = false,
  Future<void> Function()? beforeReference,
}) {
  final counters =
      captured?['telemetry']?['byProfile'] as List? ??
      [
        {
          'profile': 'one',
          'useCount': 7,
          'patchCount': 3,
          'lastPatchedAt': '2026-10-08T19:04:53Z',
        },
        {'profile': 'two', 'useCount': 4, 'patchCount': 0},
      ];
  final requests =
      captured?['activity']?['byProfile'] as List? ??
      [
        {'profile': 'one', 'view_count': 9},
        {'profile': 'two', 'view_count': 2},
      ];
  final references = captured?['references'] as List? ?? [];
  final home = '/fixture';
  final directory = path.posix.dirname(document.sourcePath!);
  final repository = SkillReaderRepository((endpoint, query) async {
    final profile = query['profile'];
    if (endpoint == 'profiles') {
      await activityReady;
      if (failActivity) throw StateError('Activity read failed');
      return {
        'profiles': [
          for (final record in counters)
            {'name': record['profile'], 'path': '$home/${record['profile']}'},
        ],
      };
    }
    if (endpoint == 'skills') {
      return {
        'data': [
          {
            'name': document.name,
            'category': captured?['category'] ?? 'productivity',
          },
        ],
      };
    }
    if (endpoint == 'analytics/usage') {
      return {
        'skills': {
          'top_skills': [
            for (final row in requests)
              if (row['profile'] == profile)
                {'skill': document.name, 'view_count': row['view_count']},
          ],
        },
      };
    }
    if (endpoint == 'fs/list') {
      final root = '$home/$profile';
      if (query['path'] == root) {
        return {
          'entries': [
            {'name': 'skills', 'path': '$root/skills', 'isDirectory': true},
          ],
        };
      }
      if (query['path'] == '$root/skills') {
        return {
          'entries': [
            {
              'name': '.usage.json',
              'path': '$root/skills/.usage.json',
              'isDirectory': false,
            },
          ],
        };
      }
      if (query['path'] == directory && references.isNotEmpty) {
        return {
          'entries': [
            {
              'name': 'references',
              'path': '$directory/references',
              'isDirectory': true,
            },
          ],
        };
      }
      if (query['path'] == '$directory/references') {
        return {
          'entries': [
            for (final file in references)
              {
                'name': file['name'],
                'path': file['path'],
                'isDirectory': false,
                'byteSize': file['preview']?['byteSize'],
              },
          ],
        };
      }
      return {'entries': []};
    }
    if (endpoint == 'fs/read-text') {
      if ((query['path'] as String).startsWith('$directory/references/')) {
        await beforeReference?.call();
      }
      return {
        'path': query['path'],
        'binary': false,
        'truncated': false,
        'text': jsonEncode({
          document.name: {
            for (final record in counters)
              if (record['profile'] == profile) ...{
                'use_count': record['useCount'],
                'patch_count': record['patchCount'],
                'last_patched_at': record['lastPatchedAt'],
              },
          },
        }),
      };
    }
    throw StateError(endpoint);
  });
  return SkillReaderSession(
    repository: repository,
    document: document.readerTarget,
    profile: 'one',
  );
}

Future<void> capture(WidgetTester tester, GlobalKey key, String label) async {
  if (!Platform.environment.containsKey('CAPTURE_SKILL_READER')) return;
  await tester.runAsync(() async {
    final render =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/skill-reader/$label.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  testWidgets(
    'skill sharing cannot supersede an active platform offer and retries after settlement',
    (tester) async {
      const channel = MethodChannel('dev.fluttercommunity.plus/share');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final entered = Completer<void>();
      final settled = Completer<String>();
      final payloads = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) {
        payloads.add((call.arguments as Map)['text'] as String);
        if (payloads.length == 1) {
          entered.complete();
          return settled.future;
        }
        return Future.value('recipient');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final pending = platformShare(ShareParams(text: 'Existing offer'));
      await entered.future;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: SkillDocumentViewer(
              document: SkillDocument.fromReceived(
                name: 'review',
                content: '# Review\n\nRead **original** evidence.',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Share content'));
        await tester.pumpAndSettle();
        expect(payloads, ['Existing offer']);
        expect(
          find.text('Finish the current share sheet, then try again.'),
          findsOneWidget,
        );
      } finally {
        settled.complete('recipient');
        await pending;
      }
      await tester.tap(find.byTooltip('Share content'));
      await tester.pumpAndSettle();
      expect(payloads, ['Existing offer', 'Review\n\nRead original evidence.']);
      expect(tester.takeException(), isNull);
    },
  );

  setUpAll(() async {
    final fonts = Platform.environment['CAPTURE_FONT_DIR'];
    if (fonts != null) {
      for (final entry in {
        'Roboto': 'Roboto-Regular.ttf',
        'MaterialIcons': 'MaterialIcons-Regular.otf',
        'monospace': 'DejaVuSansMono.ttf',
      }.entries) {
        await (FontLoader(entry.key)..addFont(
              File(
                '$fonts/${entry.value}',
              ).readAsBytes().then((b) => b.buffer.asByteData()),
            ))
            .load();
      }
    }
  });
  for (final theme in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'failed reference stays anchored and can be reopened ${theme.name} ${scale}x',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final boundary = GlobalKey();
          final held = Completer<void>();
          var attempts = 0;
          final document = SkillDocument.fromReceived(
            name: 'review',
            content: '# Review',
            sourcePath: '/skills/review/SKILL.md',
          );
          const reference = 'evidence.md';
          const referencePath = '/skills/review/references/$reference';
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: wingTheme(theme),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: SkillDocumentViewer(
                  document: document,
                  createReader: () => reader(
                    document,
                    {
                      'references': [
                        {'name': reference, 'path': referencePath},
                      ],
                    },
                    beforeReference: () async {
                      if (++attempts == 1) await held.future;
                    },
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final eye = find.byTooltip('Read $reference');
          await tester.ensureVisible(eye);
          await tester.pumpAndSettle();
          final anchor = tester.getRect(eye);
          await tester.tap(eye);
          await tester.pump();
          expect(
            find.byType(CircularProgressIndicator).hitTestable(),
            findsOneWidget,
          );
          held.completeError(StateError('Reference read failed'));
          await tester.pumpAndSettle();
          final failure = find.text('Could not open this reference.');
          expect(failure, findsOneWidget);
          expect(find.byType(Dialog), findsNothing);
          expect(tester.getRect(eye), anchor);
          expect(tester.getRect(failure).overlaps(anchor), isFalse);
          await capture(
            tester,
            boundary,
            'reference-error-${theme.name}-${scale}x',
          );
          await tester.tap(eye);
          await tester.pumpAndSettle();
          expect(failure, findsNothing);
          expect(
            tester
                .widget<SkillDocumentViewer>(find.byType(SkillDocumentViewer))
                .document
                .sourcePath,
            referencePath,
          );
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        'activity keeps its space while loading ${theme.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final semantics = tester.ensureSemantics();
          try {
            final document = SkillDocument.fromReceived(
              name: 'review',
              content: '# Review\n\n## First\nRead the evidence.',
              sourcePath: '/skills/review/SKILL.md',
              category: 'productivity',
            );
            final cases = <String, List<Map<String, Object?>>>{
              'populated': [
                {
                  'profile': 'one',
                  'useCount': 40,
                  'patchCount': 27,
                  'lastPatchedAt': '2026-10-10T12:00:00Z',
                },
              ],
              'zero': [
                {'profile': 'one', 'useCount': 0, 'patchCount': 0},
              ],
              'partial': [
                {'profile': 'one', 'useCount': 7},
              ],
              'date-only': [
                {'profile': 'one', 'lastPatchedAt': '2026-10-10T12:00:00Z'},
              ],
              'requests-only': [
                {'profile': 'one'},
              ],
              'missing': [],
              'failed': [],
            };
            for (final entry in cases.entries) {
              final ready = Completer<void>(), boundary = GlobalKey();
              final session = reader(
                document,
                {
                  'telemetry': {'byProfile': entry.value},
                  'activity': {
                    'byProfile': [
                      if (entry.key == 'requests-only')
                        {'profile': 'one', 'view_count': 9},
                    ],
                  },
                },
                activityReady: ready.future,
                failActivity: entry.key == 'failed',
              );
              await tester.pumpWidget(
                RepaintBoundary(
                  key: boundary,
                  child: MaterialApp(
                    theme: wingTheme(theme),
                    debugShowCheckedModeBanner: false,
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                        textScaler: TextScaler.linear(scale),
                        disableAnimations: true,
                      ),
                      child: child!,
                    ),
                    home: SkillDocumentViewer(
                      document: document,
                      createReader: () => session,
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              expect(find.text('Activity'), findsOneWidget);
              expect(find.text('Loading activity…'), findsOneWidget);
              expect(
                find.bySemanticsLabel('recorded uses: loading'),
                findsOneWidget,
              );
              expect(find.text('0'), findsNothing);
              final card = find
                  .ancestor(
                    of: find.text('Activity'),
                    matching: find.byType(InkWell),
                  )
                  .first;
              final loadingRect = tester.getRect(card);
              final contentTop = tester
                  .getRect(find.byTooltip('Show raw content'))
                  .top;
              await capture(
                tester,
                boundary,
                'activity-loading-${theme.name}-${scale.toInt()}',
              );
              await tester.tap(find.text('Activity'));
              await tester.pumpAndSettle();
              expect(find.byType(Dialog), findsNothing);
              ready.complete();
              await tester.pumpAndSettle();
              expect(find.text('Loading activity…'), findsNothing);
              expect(tester.getRect(card), loadingRect);
              expect(
                tester.getRect(find.byTooltip('Show raw content')).top,
                contentTop,
              );
              expect(find.text('recorded uses'), findsOneWidget);
              expect(find.text('patches / edits'), findsOneWidget);
              if (entry.key == 'populated') {
                expect(find.text('40'), findsOneWidget);
                expect(find.text('27'), findsOneWidget);
                expect(find.textContaining('Last change'), findsOneWidget);
              } else if (entry.key == 'zero') {
                expect(find.text('0'), findsNWidgets(2));
              } else if (entry.key == 'partial') {
                expect(find.text('7'), findsOneWidget);
                expect(find.text('—'), findsOneWidget);
                expect(
                  find.bySemanticsLabel('patches / edits: unavailable'),
                  findsOneWidget,
                );
              } else if (entry.key == 'date-only' ||
                  entry.key == 'requests-only') {
                expect(find.text('—'), findsNWidgets(2));
              } else {
                expect(find.text('Activity unavailable'), findsOneWidget);
                expect(find.text('0'), findsNothing);
                await tester.tap(find.text('Activity'));
                await tester.pumpAndSettle();
                expect(find.byType(Dialog), findsNothing);
              }
              expect(tester.takeException(), isNull);
              await capture(
                tester,
                boundary,
                'activity-${entry.key}-${theme.name}-${scale.toInt()}',
              );
              if (entry.key != 'missing' && entry.key != 'failed') {
                await tester.tap(find.text('Activity'));
                await tester.pumpAndSettle();
                expect(find.byType(Dialog), findsOneWidget);
                if (entry.key == 'date-only') {
                  expect(find.text('Last updated'), findsOneWidget);
                }
                if (entry.key == 'requests-only') {
                  expect(find.text('Read requests · 90 days'), findsOneWidget);
                }
                await tester.tap(find.byTooltip('Close activity'));
                await tester.pumpAndSettle();
              }
              await tester.pumpWidget(const SizedBox.shrink());
              await tester.pumpAndSettle();
            }
          } finally {
            semantics.dispose();
          }
        },
      );
      testWidgets('shared reader layout and activity ${theme.name} $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final dataFile = Platform.environment['CAPTURE_SKILL_DATA'];
        final documents = dataFile == null
            ? [
                {
                  'name': 'review',
                  'raw': demo,
                  'path': '/skills/review/SKILL.md',
                },
              ]
            : (jsonDecode(File(dataFile).readAsStringSync()) as Map)['skills']
                  as List;
        for (final data in documents) {
          final document = SkillDocument.fromReceived(
            name: data['name'] as String,
            content: data['raw'] as String,
            sourcePath: data['path'] as String,
          );
          final boundary = GlobalKey(),
              key = '${data['key'] ?? 'demo'}-${theme.name}-${scale.toInt()}';
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: MaterialApp(
                theme: wingTheme(theme),
                debugShowCheckedModeBanner: false,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: SkillDocumentViewer(
                  document: document,
                  createReader: () =>
                      reader(document, dataFile == null ? null : data as Map),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Category'), findsOneWidget);
          expect(find.text('License'), findsNothing);
          expect(find.text('recorded uses'), findsOneWidget);
          expect(find.byTooltip('Copy skill name'), findsOneWidget);
          expect(find.bySemanticsLabel('Browse sections'), findsOneWidget);
          if (document.description case final purpose?) {
            expect(
              tester.getRect(find.bySemanticsLabel('Browse sections')).top,
              greaterThan(tester.getRect(find.text(purpose)).bottom),
            );
          }
          expect(find.byTooltip('Next section').hitTestable(), findsOneWidget);
          await capture(tester, boundary, key);
          await tester.ensureVisible(
            find.textContaining(RegExp(r'^Activity(?: · \d+ tools?)?$')),
          );
          await tester.tap(
            find.textContaining(RegExp(r'^Activity(?: · \d+ tools?)?$')),
          );
          await tester.pumpAndSettle();
          expect(find.text('Uses'), findsOneWidget);
          expect(find.text('Patches / edits'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await capture(tester, boundary, '$key-activity');
          await tester.ensureVisible(find.text('Read requests · 90 days'));
          await tester.tap(find.text('Read requests · 90 days'));
          await tester.pumpAndSettle();
          await capture(tester, boundary, '$key-requests');
          expect(
            find.textContaining('Logged skill-read requests'),
            findsOneWidget,
          );
          await tester.tap(find.byTooltip('Close activity'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Next section'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        }
      });
    }
  }
  for (final theme in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'Contents fits rows, caps five and closes on repeat taps ${theme.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final heights = <int, double>{};
          for (final count in [3, 5, 9]) {
            final boundary = GlobalKey();
            await tester.pumpWidget(
              RepaintBoundary(
                key: boundary,
                child: MaterialApp(
                  theme: wingTheme(theme),
                  debugShowCheckedModeBanner: false,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: SkillDocumentViewer(
                    document: SkillDocument.fromReceived(
                      name: 'guide-$count',
                      content:
                          '# Guide\n\n${List.generate(count, (i) => '## Section ${i + 1}\n\n${i == 0 ? List.filled(20, 'Read the instructions.').join('\n\n') : 'Read the instructions.'}\n').join('\n')}',
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final opener = find.text('Section 1').last;
            await tester.tap(opener);
            await tester.pumpAndSettle();
            final modal = find.byType(BottomSheet);
            heights[count] = tester.getSize(modal).height;
            final first = find.descendant(
              of: modal,
              matching: find.text('Section 1'),
            );
            final scroll = find.descendant(
              of: modal,
              matching: find.byType(SingleChildScrollView),
            );
            expect(first.hitTestable(), findsOneWidget);
            await capture(
              tester,
              boundary,
              'contents-${theme.name}-${scale.toInt()}-$count',
            );
            expect(tester.takeException(), isNull);
            if (count > 5) {
              final lastSection = find.descendant(
                of: modal,
                matching: find.text('Section 9'),
              );
              await tester.dragUntilVisible(
                lastSection.hitTestable(),
                scroll,
                const Offset(0, -200),
                maxIteration: 10,
              );
              await tester.pumpAndSettle();
              expect(lastSection.hitTestable(), findsOneWidget);
              expect(
                tester.getRect(scroll).contains(tester.getCenter(lastSection)),
                isTrue,
              );
              expect(find.text('Contents'), findsOneWidget);
              await tester.tap(lastSection);
              await tester.pumpAndSettle();
              expect(find.byType(BottomSheet), findsNothing);
              expect(find.text('9 / 9'), findsOneWidget);
              await tester.tap(find.text('Section 9').last);
              await tester.pumpAndSettle();
            }
            await tester.tap(find.text('Contents'));
            await tester.pumpAndSettle();
            expect(find.byType(BottomSheet), findsNothing);
            final dock = find.text('Section ${count > 5 ? 9 : 1}').last;
            await tester.tap(dock);
            await tester.pumpAndSettle();
            final list = tester.getRect(
              find.descendant(
                of: find.byType(BottomSheet),
                matching: find.byType(SingleChildScrollView),
              ),
            );
            await tester.tapAt(Offset(list.left + 2, list.top + 2));
            await tester.pumpAndSettle();
            expect(find.byType(BottomSheet), findsNothing);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
          }
          expect(heights[3], lessThan(heights[5]!));
          expect(heights[9], closeTo(heights[5]!, .1));
        },
      );
    }
  }
  for (final theme in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'Reference files cap five rows and retain scrolling and opens ${theme.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final heights = <int, double>{};
          for (final count in [3, 5, 8]) {
            final document = SkillDocument.fromReceived(
              name: 'review',
              content: demo,
              sourcePath: '/skills/review/SKILL.md',
            );
            final fixture = {
              'references': [
                for (var i = 1; i <= count; i++)
                  {
                    'name': 'reference-$i.md',
                    'path': '/skills/review/references/reference-$i.md',
                    'preview': {'byteSize': 3200},
                  },
              ],
            };
            final boundary = GlobalKey();
            await tester.pumpWidget(
              RepaintBoundary(
                key: boundary,
                child: MaterialApp(
                  theme: wingTheme(theme),
                  debugShowCheckedModeBanner: false,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: SkillDocumentViewer(
                    document: document,
                    createReader: () => reader(document, fixture),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final list = find.byType(ListView);
            final scrollbar = tester.widget<Scrollbar>(find.byType(Scrollbar));
            expect(scrollbar.thumbVisibility, count > 5);
            expect(
              scrollbar.controller,
              tester.widget<ListView>(list).controller,
            );
            await tester.ensureVisible(find.text('Reference files'));
            await tester.pumpAndSettle();
            heights[count] = tester.getSize(list).height;
            final first = find.byTooltip('Read reference-1.md');
            expect(first.hitTestable(), findsOneWidget);
            await capture(
              tester,
              boundary,
              'references-${theme.name}-${scale.toInt()}-$count',
            );
            expect(tester.takeException(), isNull);
            if (count > 5) {
              await tester.drag(list, const Offset(0, -900));
              await tester.pumpAndSettle();
              final eye = find.byTooltip('Read reference-8.md');
              await tester.ensureVisible(eye);
              await tester.tap(eye);
              await tester.pumpAndSettle();
              expect(
                tester
                    .widget<SkillDocumentViewer>(
                      find.byType(SkillDocumentViewer),
                    )
                    .document
                    .sourcePath,
                '/skills/review/references/reference-8.md',
              );
              await tester.pageBack();
              await tester.pumpAndSettle();
            }
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
          }
          expect(heights[3], lessThan(heights[5]!));
          expect(heights[8], closeTo(heights[5]!, .1));
        },
      );
    }
  }
  for (final theme in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'small activity slices remain readable ${theme.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final document = SkillDocument.fromReceived(
            name: 'review',
            content: demo,
            sourcePath: '/skills/review/SKILL.md',
          );
          final fixture = {
            'telemetry': {
              'byProfile': [
                for (final record in [
                  ('default', 455, 38),
                  ('butler', 423, 28),
                  ('client-work', 50, 0),
                  ('pace', 14, 2),
                  ('reminder-inbox', 1, 0),
                  ('sluice-processing', 101, 8),
                ])
                  {
                    'profile': record.$1,
                    'useCount': record.$2,
                    'patchCount': record.$3,
                  },
              ],
            },
            'activity': {'byProfile': []},
          };
          final boundary = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: MaterialApp(
                theme: wingTheme(theme),
                debugShowCheckedModeBanner: false,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: SkillDocumentViewer(
                  document: document,
                  createReader: () => reader(document, fixture),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.textContaining(RegExp(r'^Activity(?: · \d+ tools?)?$')),
          );
          await tester.pumpAndSettle();
          expect(
            find.bySemanticsLabel(RegExp(r'^Uses: 1044\.')),
            findsOneWidget,
          );
          expect(
            find.bySemanticsLabel(RegExp(r'^Patches / edits: 76\.')),
            findsOneWidget,
          );
          expect(find.text('reminder-inbox'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await capture(
            tester,
            boundary,
            'small-slices-${theme.name}-${scale.toInt()}',
          );
        },
      );
    }
  }
  for (final theme in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'plugin instructions omit envelope and YAML in the reader ${theme.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          const banner =
              "[Bundle context: This skill is part of the 'mattpocock-skills' plugin.\nSibling skills: code-review, diagnosing-bugs.\nUse qualified form to invoke siblings (e.g. mattpocock-skills:code-review).]\n\n";
          final received =
              '$banner---\nname: writing-for-agents\ndescription: Writing documents for agents. Use when creating or editing skills, or modifying AGENTS.md or CLAUDE.md.\n---\n# Writing for agents\n\n## Purpose\n${List.filled(20, 'Read the project instructions carefully.\n\n').join()}## Workflow\nPreserve the source.';
          final boundary = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: MaterialApp(
                theme: wingTheme(theme),
                debugShowCheckedModeBanner: false,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: SkillDocumentViewer(
                  document: SkillDocument.fromReceived(
                    name: 'mattpocock-skills:writing-for-agents',
                    content: received,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.textContaining('Bundle context:'), findsNothing);
          expect(find.textContaining('name: writing-for-agents'), findsNothing);
          expect(find.text('1 / 2'), findsOneWidget);
          await capture(
            tester,
            boundary,
            'plugin-${theme.name}-${scale.toInt()}',
          );
          await tester.tap(find.text('Purpose').last);
          await tester.pumpAndSettle();
          final contents = find.byType(BottomSheet);
          expect(
            find.descendant(of: contents, matching: find.text('Purpose')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: contents, matching: find.text('Workflow')),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: contents,
              matching: find.textContaining('name:'),
            ),
            findsNothing,
          );
          await tester.tap(find.text('Contents'));
          await tester.pumpAndSettle();
          final raw = find.byTooltip('Show raw content');
          await tester.ensureVisible(raw);
          await tester.tap(raw);
          await tester.pumpAndSettle();
          expect(find.text(received), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'grip is dedicated, tolerates drift, tracks continuously and cancels',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final content =
          '$demo${List.generate(30, (i) => '\nParagraph $i. More evidence.\n').join()}\n## Third\nFinal checks.';
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: SkillDocumentViewer(
            document: SkillDocument.fromReceived(
              name: 'review',
              content: content,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final grip = find.bySemanticsLabel('Browse sections');
      BoxDecoration gripPaint() =>
          tester
                  .widget<Container>(
                    find.descendant(
                      of: grip,
                      matching: find.byWidgetPredicate(
                        (w) => w is Container && w.decoration is BoxDecoration,
                      ),
                    ),
                  )
                  .decoration!
              as BoxDecoration;
      final restingPaint = gripPaint();
      expect(grip.hitTestable(), findsOneWidget);
      await tester.tap(grip);
      await tester.pumpAndSettle();
      expect(find.text('Contents'), findsNothing);
      final position = tester.getCenter(grip);
      final gesture = await tester.startGesture(position);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('1 · First'), findsNothing);
      await gesture.moveBy(const Offset(0, 8));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('1 · First'), findsOneWidget);
      expect(gripPaint().color, isNot(restingPaint.color));
      expect(tester.getCenter(grip).dy, closeTo(position.dy + 8, .5));
      await gesture.moveBy(const Offset(0, 32));
      await tester.pump();
      expect(tester.getCenter(grip).dy, closeTo(position.dy + 40, .5));
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(find.textContaining(' · First'), findsNothing);
      expect(gripPaint(), restingPaint);
      final pending = await tester.startGesture(tester.getCenter(grip));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining(' · First'), findsNothing);
      await pending.cancel();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.tap(find.text('First').last);
      await tester.pumpAndSettle();
      expect(find.text('Contents'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      await tester.tap(find.text('Third').last);
      await tester.pumpAndSettle();
      expect(find.text('3 / 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'name and document copy have distinct scopes and displayed mode',
    (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: SkillDocumentViewer(
            document: SkillDocument.fromReceived(name: 'review', content: demo),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Copy skill name'));
      await tester.pump();
      expect(copied, 'review');
      await tester.ensureVisible(find.byTooltip('Copy content'));
      await tester.tap(find.byTooltip('Copy content'));
      await tester.pump();
      expect(copied, contains('Read original evidence.'));
      expect(copied, isNot(contains('license: MIT')));
      await tester.tap(find.byTooltip('Show raw content'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Copy content'));
      await tester.tap(find.byTooltip('Copy content'));
      await tester.pump();
      expect(copied, demo);
      expect(find.bySemanticsLabel('Browse sections'), findsNothing);
    },
  );
}
