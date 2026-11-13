import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/chat_reading_session.dart';
import 'package:wing/core/widgets/chat_find_sheet.dart';
import 'package:wing/core/widgets/studio_loading.dart';

ProfileHistoryPage page(
  List<Map<String, dynamic>> rows, {
  int offset = 0,
  int limit = 500,
}) => ProfileHistoryPage('chat', rows, offset, limit);

void main() {
  const capture = bool.fromEnvironment('CAPTURE_FIND_FEEDBACK');
  setUpAll(() async {
    if (!capture) return;
    const fonts = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final font in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            File(
              '$fonts/${font.value}',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });

  Future<void> captureFrame(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('find-capture')),
    );
    await tester.runAsync(() async {
      final bitmap = await boundary.toImage();
      try {
        final bytes = await bitmap.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/design-previews/find-feedback/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        bitmap.dispose();
      }
    });
  }

  for (final brightness in Brightness.values) {
    for (final enlarged in [false, true]) {
      for (final outcome in ['success', 'failure', 'departure']) {
        final name =
            '${brightness.name}-${enlarged ? 'large-reduced' : 'normal'}-$outcome';
        testWidgets('older search retains visible feedback through $name', (
          tester,
        ) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(enlarged ? 320 : 390, 844);
          addTearDown(tester.view.reset);
          final pending = Completer<ProfileHistoryPage>();
          addTearDown(() {
            if (!pending.isCompleted) pending.complete(page([], offset: 500));
          });
          var olderReads = 0;
          await tester.pumpWidget(
            RepaintBoundary(
              key: const Key('find-capture'),
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(enlarged ? 2 : 1),
                    disableAnimations: enlarged,
                  ),
                  child: child!,
                ),
                home: _findSheet(
                  loadHistory: (offset) {
                    if (offset == 0) {
                      return Future.value(
                        page([
                          for (var i = 0; i < 500; i++)
                            {
                              'id': i + 501,
                              'role': 'assistant',
                              'content': i == 499
                                  ? 'recent needle'
                                  : 'filler $i',
                            },
                        ]),
                      );
                    }
                    olderReads++;
                    return olderReads == 1
                        ? pending.future
                        : Future.value(
                            page([
                              {
                                'id': 1,
                                'role': 'assistant',
                                'content': 'older needle',
                              },
                            ], offset: 500),
                          );
                  },
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), 'needle');
          await tester.pumpAndSettle();
          final header = tester.getRect(find.byType(TextField));
          final olderSearch = find.byTooltip('Search older messages');
          await tester.ensureVisible(olderSearch);
          await tester.pumpAndSettle();
          expect(olderSearch.hitTestable(), findsOneWidget);
          await tester.tap(olderSearch);
          await tester.pump();
          await tester.pump();
          expect(olderReads, 1);
          final feedback = find.byType(StudioLoading);
          expect(feedback, findsOneWidget);
          expect(tester.getSize(feedback).shortestSide, greaterThan(0));
          expect(tester.getRect(find.byType(TextField)), header);
          expect(find.text('recent needle').hitTestable(), findsOneWidget);
          await tester.tap(find.byTooltip('Search older messages'));
          await tester.pump(const Duration(milliseconds: 250));
          expect(olderReads, 1);
          expect(feedback, findsOneWidget);
          await captureFrame(tester, '$name-pending');
          if (outcome == 'departure') {
            await tester.pumpWidget(
              const MaterialApp(home: Text('Search closed')),
            );
            pending.complete(page([], offset: 500));
            await tester.pumpAndSettle();
            expect(find.text('Search closed'), findsOneWidget);
            expect(feedback, findsNothing);
          } else if (outcome == 'failure') {
            pending.completeError(StateError('synthetic search failure'));
            await tester.pumpAndSettle();
            expect(feedback, findsNothing);
            expect(find.text('recent needle'), findsOneWidget);
            await tester.ensureVisible(find.byTooltip('Retry search'));
            await tester.pumpAndSettle();
            expect(
              find.byTooltip('Retry search').hitTestable(),
              findsOneWidget,
            );
            await captureFrame(tester, '$name-failed');
            await tester.tap(find.byTooltip('Retry search'));
            await tester.pumpAndSettle();
            expect(find.text('older needle'), findsOneWidget);
            expect(olderReads, 2);
          } else {
            pending.complete(
              page([
                {'id': 1, 'role': 'assistant', 'content': 'older needle'},
              ], offset: 500),
            );
            await tester.pumpAndSettle();
            expect(feedback, findsNothing);
            expect(find.text('older needle'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('returns the source page and row ID for a selected match', (
    tester,
  ) async {
    ProfileHistoryPage? selectedPage;
    int? selectedRow;
    bool? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              selected = await _showFind(
                context,
                show: (page, rowId) {
                  selectedPage = page;
                  selectedRow = rowId;
                  return true;
                },
                loadHistory: (offset) async => page([
                  {
                    'id': 42,
                    'role': 'assistant',
                    'content': 'Find this saved answer',
                  },
                ], offset: 500),
              );
            },
            child: const Text('Open Find'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Find'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'saved answer');
    await tester.pump();
    await tester.tap(find.text('Find this saved answer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View in chat'));
    await tester.pumpAndSettle();

    expect(selected, isTrue);
    expect(selectedRow, 42);
    expect(selectedPage?.offset, 500);
    expect(selectedPage?.rows.single['content'], 'Find this saved answer');
  });

  testWidgets('loads the recent page once and filters message text locally', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: _findSheet(
          loadHistory: (offset) async {
            calls++;
            expect(offset, 0);
            return page([
              {
                'id': 1,
                'role': 'user',
                'content': 'Need the deployment checklist',
              },
              {
                'id': 2,
                'role': 'assistant',
                'content': 'Here is the checklist',
              },
            ]);
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(calls, 1);
    await tester.enterText(find.byType(TextField), 'deployment');
    await tester.pump();
    expect(find.text('Need the deployment checklist'), findsOneWidget);
    expect(find.text('Here is the checklist'), findsNothing);
    expect(find.text('1 matching message'), findsOneWidget);
    expect(calls, 1);
  });

  testWidgets('keeps recent matches first after loading older messages', (
    tester,
  ) async {
    final older = Completer<ProfileHistoryPage>();
    var olderReads = 0;
    addTearDown(() {
      if (!older.isCompleted) older.complete(page([]));
    });
    await tester.pumpWidget(
      MaterialApp(
        home: _findSheet(
          loadHistory: (offset) async {
            if (offset > 0) {
              olderReads++;
              return older.future;
            }
            return page([
              {
                'id': 501,
                'role': 'assistant',
                'content': 'recent earlier needle',
              },
              for (var i = 502; i < 1000; i++)
                {'id': i, 'content': 'recent filler $i'},
              {
                'id': 1000,
                'role': 'assistant',
                'content': 'recent newest needle',
              },
            ]);
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.enterText(find.byType(TextField), 'needle');
    await tester.pump();

    expect(
      tester
          .widgetList<ExpansionTile>(find.byType(ExpansionTile))
          .map((tile) => (tile.title as Text).data),
      ['recent newest needle', 'recent earlier needle'],
    );

    await tester.tap(find.byTooltip('Search older messages'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Searching older messages…'), findsNothing);
    expect(find.byTooltip('Search older messages'), findsOneWidget);
    expect(find.byType(StudioLoading), findsOneWidget);
    expect(
      tester.widget<StudioLoading>(find.byType(StudioLoading)).label,
      'Searching messages',
    );
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is IconButton &&
                  widget.tooltip == 'Search older messages',
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('Search older messages'));
    await tester.pump(const Duration(seconds: 2));
    expect(olderReads, 1);
    expect(find.byType(StudioLoading), findsOneWidget);
    expect(find.text('recent newest needle'), findsOneWidget);
    older.complete(
      page([
        {'id': 1, 'role': 'assistant', 'content': 'oldest needle'},
        {'id': 500, 'role': 'assistant', 'content': 'older newest needle'},
      ], offset: 500),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byType(StudioLoading), findsNothing);

    expect(
      tester
          .widgetList<ExpansionTile>(find.byType(ExpansionTile))
          .map((tile) => (tile.title as Text).data),
      [
        'recent newest needle',
        'recent earlier needle',
        'older newest needle',
        'oldest needle',
      ],
    );
  });

  testWidgets('initial failures use friendly retry and close actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: _findSheet(loadHistory: (_) async => throw StateError('offline')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.textContaining("Couldn't search this chat"), findsOneWidget);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.byTooltip('Retry search'), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);
  });

  testWidgets('shows every loaded match and expands full selectable text', (
    tester,
  ) async {
    final longText = List.filled(12, 'needle line').join('\n');
    await tester.pumpWidget(
      MaterialApp(
        home: _findSheet(
          loadHistory: (_) async => page([
            ...List.generate(
              100,
              (index) => {
                'id': index + 1,
                'role': 'user',
                'content': 'needle ${index + 1}',
              },
            ),
            {'id': 101, 'role': 'assistant', 'content': longText},
          ]),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.enterText(find.byType(TextField), 'needle');
    await tester.pump();
    expect(find.text('101 matching messages'), findsOneWidget);
    await tester.tap(find.byType(ExpansionTile).first);
    await tester.pump();
    expect(find.byType(SelectableText), findsOneWidget);
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      longText,
    );
    await tester.scrollUntilVisible(
      find.text('needle 1'),
      300,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            ),
          )
          .first,
      maxScrolls: 100,
    );
    await tester.pumpAndSettle();
    expect(find.text('needle 1'), findsOneWidget);
  });

  testWidgets('expanded long result keeps View in chat visible', (
    tester,
  ) async {
    final longText = List.filled(200, 'needle detail').join('\n');
    await tester.pumpWidget(
      MaterialApp(
        home: _findSheet(
          loadHistory: (_) async => page([
            {'id': 1, 'role': 'assistant', 'content': longText},
          ]),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.enterText(find.byType(TextField), 'needle');
    await tester.pump();

    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();

    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('View in chat').hitTestable(), findsOneWidget);
  });

  testWidgets(
    'older-page failure preserves matches and retries the same page',
    (tester) async {
      var olderAttempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: _findSheet(
            loadHistory: (offset) async {
              if (offset == 0) {
                return page([
                  for (var i = 0; i < 500; i++)
                    {
                      'id': i + 501,
                      'role': 'assistant',
                      'content': i == 499 ? 'recent needle' : 'recent $i',
                    },
                ]);
              }
              olderAttempts++;
              if (olderAttempts == 1) throw StateError('offline');
              return page([
                {
                  'id': 1000,
                  'role': 'assistant',
                  'content': 'overlapping duplicate needle',
                },
                {'id': 1, 'role': 'user', 'content': 'older needle'},
              ], offset: offset);
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.enterText(find.byType(TextField), 'needle');
      await tester.pump();
      expect(
        find.text('1 matching message in loaded messages'),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Search older messages'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('recent needle'), findsOneWidget);
      expect(
        find.textContaining('current results are still here'),
        findsOneWidget,
      );
      expect(find.textContaining('Bad state'), findsNothing);
      await tester.tap(find.byTooltip('Retry search'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(olderAttempts, 2);
      expect(find.text('older needle'), findsOneWidget);
      expect(find.text('recent needle'), findsOneWidget);
      expect(find.text('overlapping duplicate needle'), findsNothing);
      expect(find.text('2 matching messages'), findsOneWidget);
      expect(find.byTooltip('Search older messages'), findsNothing);
    },
  );

  testWidgets('partial no-match copy changes when history is exhausted', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: _findSheet(
          loadHistory: (offset) async => offset == 0
              ? page([
                  for (var i = 0; i < 500; i++)
                    {'id': i + 501, 'content': 'recent $i'},
                ])
              : page([
                  {'id': 1, 'content': 'oldest'},
                ], offset: offset),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.enterText(find.byType(TextField), 'absent');
    await tester.pump();
    expect(
      find.text('No matches in the messages loaded so far.'),
      findsOneWidget,
    );
    expect(find.text('No matching messages.'), findsNothing);
    await tester.tap(find.byTooltip('Search older messages'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('No matching messages.'), findsOneWidget);
    expect(find.byTooltip('Search older messages'), findsNothing);
  });

  testWidgets(
    'retry layout fits a narrow screen with large text and keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          home: _findSheet(
            loadHistory: (_) async => throw StateError('offline'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Retry search'), findsOneWidget);
      expect(find.byTooltip('Close'), findsOneWidget);
    },
  );

  testWidgets(
    'older-page failure fits a narrow screen with results and keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          home: _findSheet(
            loadHistory: (offset) async {
              if (offset > 0) throw StateError('offline');
              return page([
                for (var i = 0; i < 500; i++)
                  {
                    'id': i + 1,
                    'role': 'assistant',
                    'content': i == 499 ? 'recent needle' : 'recent $i',
                  },
              ]);
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.enterText(find.byType(TextField), 'needle');
      await tester.pump();
      await tester.ensureVisible(find.byTooltip('Search older messages'));
      await tester.pump();
      await tester.tap(find.byTooltip('Search older messages'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(tester.takeException(), isNull);
      expect(find.text('recent needle'), findsOneWidget);
      expect(
        find.text('1 matching message in loaded messages'),
        findsOneWidget,
      );
      expect(
        find.textContaining('current results are still here'),
        findsOneWidget,
      );
      expect(find.byTooltip('Retry search'), findsOneWidget);
      expect(find.byTooltip('Close'), findsOneWidget);
    },
  );
}

Widget _findSheet({
  required Future<ProfileHistoryPage> Function(int) loadHistory,
}) => ChatFindSheet(
  createSession: () => ChatReadingSession(
    _FindSource(loadHistory: loadHistory, showPage: (_, _) => true),
  ),
);

Future<bool?> _showFind(
  BuildContext context, {
  required Future<ProfileHistoryPage> Function(int) loadHistory,
  required bool Function(ProfileHistoryPage, int) show,
}) => showChatFindSheet(
  context,
  createSession: () =>
      ChatReadingSession(_FindSource(loadHistory: loadHistory, showPage: show)),
);

final class _FindSource extends ChangeNotifier implements ChatReadingSource {
  _FindSource({required this.loadHistory, required this.showPage});
  final Future<ProfileHistoryPage> Function(int) loadHistory;
  final bool Function(ProfileHistoryPage, int) showPage;
  @override
  bool get current => true;
  @override
  Future<ProfileHistoryPage> load(int offset) => loadHistory(offset);
  @override
  bool show(ProfileHistoryPage page, int rowId) => showPage(page, rowId);
}
