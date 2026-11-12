import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/widgets/studio_action_label.dart';
import 'package:wing/core/widgets/activity/activity_detail_actions.dart';

void main() {
  testWidgets('static pulse matches the canonical notification Wing mark', (
    tester,
  ) async {
    final source = File('assets/icon/wing.svg').readAsStringSync();
    final data = RegExp(r' d="([^"]+)"').firstMatch(source)!.group(1)!;
    expect(
      File(
        'android/app/src/main/res/drawable/ic_stat_wing.xml',
      ).readAsStringSync(),
      contains('android:pathData="$data"'),
    );
    final tokens = RegExp(
      r'[MCZ]|-?\d+(?:\.\d+)?',
    ).allMatches(data).map((m) => m.group(0)!).toList();
    final path = Path();
    var position = 0;
    double number() => double.parse(tokens[position++]);
    while (position < tokens.length) {
      switch (tokens[position++]) {
        case 'M':
          path.moveTo(number(), number());
        case 'C':
          path.cubicTo(
            number(),
            number(),
            number(),
            number(),
            number(),
            number(),
          );
        case 'Z':
          path.close();
        default:
          throw StateError('Update canonical SVG command support');
      }
    }
    final frame = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Center(
            child: RepaintBoundary(
              key: frame,
              child: const StudioLoading(
                label: 'Canonical Wing',
                size: 24,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      final actual =
          await (frame.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      final recording = ui.PictureRecorder();
      final canvas = Canvas(recording);
      canvas.drawPath(path, Paint()..color = Colors.white);
      final picture = recording.endRecording();
      final expected = await picture.toImage(24, 24);
      expect(
        (await actual.toByteData())!.buffer.asUint8List(),
        orderedEquals((await expected.toByteData())!.buffer.asUint8List()),
      );
      actual.dispose();
      expected.dispose();
      picture.dispose();
    });
  });

  testWidgets(
    'header refresh owns the Wing pulse until conversation work resumes',
    (tester) async {
      var refreshing = false;
      late StateSetter change;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: const [StudioLoadingSlot(), StudioLoadingSlot()],
            ),
            body: StatefulBuilder(
              builder: (context, setState) {
                change = setState;
                return StudioPageLoading(
                  active: refreshing,
                  label: 'Refreshing group',
                  child: const Row(
                    children: [
                      StudioWorkingIndicator(
                        label: 'Nested tool work',
                        color: Colors.teal,
                      ),
                      StudioWorkingIndicator(
                        conversation: true,
                        label: 'Bots are working',
                        color: Colors.teal,
                      ),
                      Text('Bots are working'),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(StudioLoading), findsOneWidget);
      final before = tester.getRect(find.text('Bots are working'));
      change(() => refreshing = true);
      await tester.pump();
      await tester.pump();
      expect(find.byType(StudioLoading), findsOneWidget);
      expect(
        tester.widget<StudioLoading>(find.byType(StudioLoading)).label,
        'Refreshing group',
      );
      expect(find.byTooltip('Refreshing group'), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsNothing);
      expect(
        find.descendant(
          of: find.byType(StudioLoadingSlot),
          matching: find.byType(StudioLoading),
        ),
        findsOneWidget,
      );
      // Conversation status keeps its artwork while the header owns animation.
      expect(
        find.descendant(
          of: find.byType(StudioWorkingIndicator),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.pending_outlined), findsNothing);
      expect(tester.getRect(find.text('Bots are working')), before);
      change(() => refreshing = false);
      await tester.pump();
      await tester.pump();
      expect(find.byType(StudioLoading), findsOneWidget);
      expect(
        tester.widget<StudioLoading>(find.byType(StudioLoading)).label,
        'Bots are working',
      );
    },
  );

  testWidgets('independent working items each retain their pulse', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              StudioWorkingIndicator.independent(
                label: 'Atlas running',
                color: Colors.teal,
              ),
              StudioWorkingIndicator.independent(
                label: 'Mira running',
                color: Colors.teal,
              ),
              Icon(Icons.chat_bubble_outline, size: 18, color: Colors.teal),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(StudioLoading), findsNWidgets(2));
    expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
  });

  testWidgets(
    'hidden work and header slots cannot retain the visible placement',
    (tester) async {
      var hidden = false;
      late StateSetter change;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                change = setState;
                return Column(
                  children: [
                    TickerMode(
                      enabled: !hidden,
                      child: const StudioWorkingIndicator(
                        label: 'First',
                        color: Colors.teal,
                      ),
                    ),
                    const StudioWorkingIndicator(
                      label: 'Visible work',
                      color: Colors.teal,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        tester.widget<StudioLoading>(find.byType(StudioLoading)).label,
        'First',
      );
      change(() => hidden = true);
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<StudioLoading>(find.byType(StudioLoading)).label,
        'Visible work',
      );
      expect(tester.binding.transientCallbackCount, 1);
    },
  );

  testWidgets('modal header pauses underlying conversation work', (
    tester,
  ) async {
    late BuildContext page;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(actions: const [StudioLoadingSlot()]),
          body: Builder(
            builder: (context) {
              page = context;
              return const Row(
                children: [
                  StudioWorkingIndicator(
                    conversation: true,
                    label: 'Hermes is working',
                    color: Colors.teal,
                  ),
                  Text('Hermes is working'),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(StudioLoading), findsOneWidget);
    unawaited(
      showModalBottomSheet<void>(
        context: page,
        builder: (_) => const StudioLoadingFrame(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              StudioLoadingSlot(),
              StudioPageLoading.waiting(label: 'Modal read'),
              Text('Models'),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byType(StudioLoading), findsOneWidget);
    expect(
      tester.widget<StudioLoading>(find.byType(StudioLoading)).label,
      'Modal read',
    );
    expect(find.text('Hermes is working'), findsOneWidget);
    expect(find.byIcon(Icons.pending_outlined), findsNothing);
    expect(
      find.descendant(
        of: find.byType(StudioWorkingIndicator),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
    Navigator.of(page).pop();
    await tester.pump();
    expect(find.byIcon(Icons.pending_outlined), findsNothing);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byType(StudioLoading), findsOneWidget);
    expect(
      tester.widget<StudioLoading>(find.byType(StudioLoading)).label,
      'Hermes is working',
    );
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('action icons stay fixed ${brightness.name} $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final semantics = tester.ensureSemantics();
        try {
          var busy = false;
          var taps = 0;
          late StateSetter change;
          final frame = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(key: frame, child: child!),
              ),
              home: Scaffold(
                appBar: AppBar(title: const Text('Action icons')),
                body: StatefulBuilder(
                  builder: (_, setState) {
                    change = setState;
                    return ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        TextButton(
                          key: const Key('compact-action'),
                          onPressed: busy ? null : () => taps++,
                          child: StudioActionLabel.compact(
                            'Open',
                            busy: busy,
                            icon: Icons.open_in_new,
                          ),
                        ),
                        TextButton(
                          key: const Key('row-action'),
                          onPressed: busy ? null : () => taps++,
                          child: StudioActionLabel.row(
                            'Support Wing',
                            busy: busy,
                            icon: Icons.favorite_outline,
                          ),
                        ),
                        ActivityDetailAction(
                          label: 'Preview file',
                          icon: Icons.visibility_outlined,
                          busy: busy,
                          onPressed: () => taps++,
                        ),
                        TextButton(
                          onPressed: () => taps++,
                          child: const Text('Cancel'),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          );
          final iconRects = {
            for (final icon in [
              Icons.open_in_new,
              Icons.favorite_outline,
              Icons.visibility_outlined,
            ])
              icon: tester.getRect(find.byIcon(icon)),
          };
          final buttonRect = tester.getRect(find.byTooltip('Preview file'));
          for (final phase in ['pending', 'ready']) {
            change(() => busy = phase == 'pending');
            await tester.pump(const Duration(milliseconds: 350));
            for (final icon in iconRects.keys) {
              if (busy && icon == Icons.visibility_outlined) {
                expect(find.byIcon(icon), findsNothing);
                expect(find.byType(CircularProgressIndicator), findsOneWidget);
              } else {
                expect(find.byIcon(icon), findsOneWidget);
                expect(tester.getRect(find.byIcon(icon)), iconRects[icon]);
              }
            }
            expect(tester.getRect(find.byTooltip('Preview file')), buttonRect);
            if (busy) {
              await tester.tap(find.byTooltip('Preview file'));
              expect(taps, 0);
            }
            expect(find.byType(StudioLoading), findsNothing);
            final action = find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == 'Preview file',
            );
            expect(
              tester.widget<IconButton>(action).onPressed,
              busy ? isNull : isNotNull,
            );
            expect(
              find.bySemanticsLabel(busy ? 'Open, in progress' : 'Open'),
              findsOneWidget,
            );
            await tester.tap(find.text('Cancel'));
            expect(taps, phase == 'pending' ? 1 : 2);
            expect(tester.takeException(), isNull);
            if (const bool.fromEnvironment('STUDIO_LOADING_REVIEW')) {
              await tester.runAsync(() async {
                final boundary =
                    frame.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary;
                final pixels = await boundary.toImage();
                final bytes = await pixels.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final directory = Directory(
                  'build/design-previews/loading-family/site/actions',
                )..createSync(recursive: true);
                await File(
                  '${directory.path}/${brightness.name}-$scale-$phase.png',
                ).writeAsBytes(bytes!.buffer.asUint8List());
                pixels.dispose();
              });
            }
          }
          await tester.tap(find.byTooltip('Preview file'));
          expect(taps, 3);
        } finally {
          semantics.dispose();
        }
      });
    }
  }

  setUpAll(() async {
    if (!const bool.fromEnvironment('STUDIO_LOADING_REVIEW') &&
        !const bool.fromEnvironment('CAPTURE_LOADING_CORRECTIONS')) {
      return;
    }
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
      'WingIcons': 'assets/fonts/wing-icons.ttf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(entry.value).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });
  for (final reduced in [false, true]) {
    testWidgets(
      'active work uses the pulse in one fixed status slot reduced=$reduced',
      (tester) async {
        var active = true;
        var visible = true;
        var taps = 0;
        late StateSetter change;
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                change = setState;
                return MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(disableAnimations: reduced),
                  child: TickerMode(
                    enabled: visible,
                    child: Scaffold(
                      appBar: AppBar(actions: const [StudioLoadingSlot()]),
                      body: Row(
                        children: [
                          if (active)
                            StudioWorkingIndicator(
                              label: 'Hermes is working',
                              color: Colors.teal,
                            )
                          else
                            const Icon(
                              Icons.help_outline,
                              size: 18,
                              color: Colors.teal,
                            ),
                          const SizedBox(width: 8),
                          const Text('Work status'),
                          IconButton(
                            tooltip: 'Stop work',
                            onPressed: () => taps++,
                            icon: const Icon(Icons.stop),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
        await tester.pump();
        final statusRect = tester.getRect(find.text('Work status'));
        final actionRect = tester.getRect(find.byTooltip('Stop work'));
        expect(find.byType(StudioLoading), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 350));
        expect(tester.binding.transientCallbackCount, reduced ? 0 : 1);
        expect(tester.getRect(find.text('Work status')), statusRect);
        await tester.tap(find.byTooltip('Stop work'));
        expect(taps, 1);
        change(() => visible = false);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.binding.transientCallbackCount, 0);
        change(() {
          visible = true;
          active = false;
        });
        await tester.pump();
        expect(find.byType(StudioLoading), findsNothing);
        expect(find.byIcon(Icons.help_outline), findsOneWidget);
        expect(tester.getRect(find.text('Work status')), statusRect);
        expect(tester.getRect(find.byTooltip('Stop work')), actionRect);
        expect(find.byType(ShaderMask), findsNothing);
      },
    );
  }
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('loading family render ${brightness.name} $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var available = false;
        late StateSetter change;
        final frame = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: RepaintBoundary(key: frame, child: child!),
            ),
            home: Scaffold(
              appBar: AppBar(
                title: const Text('Wing loading'),
                actions: const [StudioLoadingSlot()],
              ),
              body: StatefulBuilder(
                builder: (_, setState) {
                  change = setState;
                  return StudioLoadingRegion(
                    busy: true,
                    available: available,
                    label: 'Loading chats',
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        const SizedBox(height: 24),
                        const Text(
                          'Your workspace',
                          style: TextStyle(fontSize: 24),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          available
                              ? 'Saved chats are ready.'
                              : 'Waiting for your first chats.',
                        ),
                        const SizedBox(height: 24),
                        ListTile(
                          title: const Text('Saving changes'),
                          trailing: const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(
                              semanticsLabel: 'Saving changes',
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        IconButton(
                          tooltip: 'Cancel',
                          onPressed: () {},
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        );
        for (final phase in ['blocked', 'ready']) {
          change(() => available = phase == 'ready');
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pump();
          expect(
            find.byType(StudioLoading),
            available ? findsNothing : findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          if (const bool.fromEnvironment('STUDIO_LOADING_REVIEW')) {
            await tester.runAsync(() async {
              final boundary =
                  frame.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final pixels = await boundary.toImage();
              final bytes = await pixels.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final directory = Directory(
                'build/design-previews/loading-family/site/renders',
              )..createSync(recursive: true);
              await File(
                '${directory.path}/${brightness.name}-$scale-$phase.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
              pixels.dispose();
            });
          }
        }
      });
    }
  }
  testWidgets(
    'held background read stays quiet, usable and publishes new data',
    (tester) async {
      var busy = false;
      var title = 'Saved chats';
      var taps = 0;
      late StateSetter change;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(actions: const [StudioLoadingSlot()]),
            body: StatefulBuilder(
              builder: (_, setState) {
                change = setState;
                return StudioLoadingRegion(
                  busy: busy,
                  available: true,
                  label: 'Loading chats',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(title),
                      TextButton(
                        onPressed: () => taps++,
                        child: const Text('Open'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );
      final before = tester.getRect(find.text('Open'));
      change(() => busy = true);
      await tester.pump(const Duration(seconds: 12));
      expect(find.byType(StudioLoading), findsNothing);
      expect(tester.getRect(find.text('Open')), before);
      await tester.tap(find.text('Open'));
      expect(taps, 1);
      change(() {
        busy = false;
        title = 'Updated chats';
      });
      await tester.pump();
      expect(find.text('Updated chats'), findsOneWidget);
      expect(tester.getRect(find.text('Open')), before);
    },
  );
  testWidgets('loading preserves region geometry and pointer access', (
    tester,
  ) async {
    var busy = false;
    var taps = 0;
    late StateSetter change;
    final content = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(actions: const [StudioLoadingSlot()]),
          body: StatefulBuilder(
            builder: (_, setState) {
              change = setState;
              return StudioLoadingRegion(
                available: false,
                busy: busy,
                label: 'Loading chats',
                child: Column(
                  children: [
                    const SizedBox(height: 16),
                    TextButton(
                      key: content,
                      onPressed: () => taps++,
                      child: const Text('Cancel'),
                    ),
                    const Expanded(child: SizedBox()),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    final before = tester.getRect(find.byKey(content));
    change(() => busy = true);
    await tester.pump();
    await tester.pump();
    final loading = find.byType(StudioLoading);
    expect(loading, findsOneWidget);
    expect(tester.getRect(find.byKey(content)), before);
    expect(tester.getSemantics(loading).label, 'Loading chats');
    await tester.tap(find.byKey(content));
    expect(taps, 1);
    await tester.pump(const Duration(milliseconds: 550));
    expect(tester.getRect(find.byKey(content)), before);
    change(() => busy = false);
    await tester.pump();
    await tester.pump();
    expect(loading, findsNothing);
    expect(tester.getRect(find.byKey(content)), before);
  });

  testWidgets('nested regions use one cue and preserve local action feedback', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(actions: const [StudioLoadingSlot()]),
          body: const StudioLoadingRegion(
            available: false,
            busy: true,
            label: 'Loading workspace',
            child: StudioLoadingRegion(
              busy: true,
              label: 'Loading chats',
              available: false,
              child: Center(
                child: SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(
                    semanticsLabel: 'Saving file',
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(StudioLoading), findsOneWidget);
    expect(find.bySemanticsLabel('Loading workspace'), findsOneWidget);
    expect(find.bySemanticsLabel('Loading chats'), findsNothing);
    expect(find.bySemanticsLabel('Saving file'), findsOneWidget);
  });

  for (final reduced in [false, true]) {
    testWidgets('motion admission and stable semantics reduced=$reduced', (
      tester,
    ) async {
      var visible = true;
      late StateSetter change;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              change = setState;
              return MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(disableAnimations: reduced),
                child: TickerMode(
                  enabled: visible,
                  child: const StudioLoading(label: 'Preparing file'),
                ),
              );
            },
          ),
        ),
      );
      final loading = find.byType(StudioLoading);
      final before = tester.getRect(loading);
      await tester.pump(const Duration(milliseconds: 550));
      expect(tester.getRect(loading), before);
      expect(tester.getSemantics(loading).label, 'Preparing file');
      expect(tester.binding.transientCallbackCount, reduced ? 0 : 1);
      change(() => visible = false);
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      change(() => visible = true);
      await tester.pump();
      expect(tester.binding.transientCallbackCount, reduced ? 0 : 1);
    });
  }

  for (final available in [false, true]) {
    testWidgets('pull refresh respects available=$available', (tester) async {
      final complete = Completer<void>();
      var refreshes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(actions: const [StudioLoadingSlot()]),
            body: StudioRefresh(
              available: available,
              onRefresh: () {
                refreshes++;
                return complete.future;
              },
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [SizedBox(height: 800, child: Text('Chats'))],
              ),
            ),
          ),
        ),
      );
      final before = tester.getTopLeft(find.text('Chats'));
      await tester.drag(find.byType(ListView), const Offset(0, 600));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(refreshes, 1);
      expect(
        find.byType(StudioLoading),
        available ? findsNothing : findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      complete.complete();
      await tester.pumpAndSettle();
      expect(find.byType(StudioLoading), findsNothing);
      expect(tester.getTopLeft(find.text('Chats')), before);
    });
  }
}
