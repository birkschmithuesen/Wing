import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_error.dart';

const _export = bool.fromEnvironment('CAPTURE_STUDIO_ERRORS');
const _noSpeech = 'No speech detected';
const _hint = 'Tap the microphone and speak again.';
final _captureKey = GlobalKey();

class _CaptureBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get disableShadows => false;
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_export) return;
  await tester.runAsync(() async {
    final boundary =
        _captureKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final image = await boundary.toImage();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/design-previews/studio-errors/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

Future<void> _show(
  WidgetTester tester, {
  required Widget child,
  Brightness brightness = Brightness.light,
  double scale = 1,
  double keyboard = 0,
}) async {
  tester.view.physicalSize = const Size(390, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _captureKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: wingTheme(brightness, accent: Colors.purple),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(viewInsets: EdgeInsets.only(bottom: keyboard)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: true,
              ),
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _trigger(
  String name, {
  String message = _noSpeech,
  Object errorKey = 'dictation/no-speech',
  bool retryClears = false,
}) => Builder(
  builder: (anchor) => IconButton(
    tooltip: name,
    icon: const Icon(Icons.mic_none),
    onPressed: () {
      if (retryClears) dismissTransientError(anchor, errorKey: errorKey);
      showTransientError(
        anchor,
        message,
        errorKey: errorKey,
        icon: Icons.mic_none,
        severity: StudioErrorSeverity.noResult,
        detail: _hint,
      );
    },
  ),
);

Finder _floating() => find.byWidgetPredicate(
  (widget) => widget is StudioErrorFrame && widget.floating,
);

void main() {
  if (_export) _CaptureBinding();
  setUpAll(() async {
    if (!_export) return;
    const dir = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final font in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            File('$dir/${font.value}').readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('Studio error family at ${brightness.name}, $scale text', (
        tester,
      ) async {
        const anchorKey = ValueKey('composer');
        await _show(
          tester,
          brightness: brightness,
          scale: scale,
          keyboard: 210,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const StudioError(
                  'Could not save settings',
                  detail: 'Your edits are still here. Try saving again.',
                ),
                const Spacer(),
                Builder(
                  builder: (anchor) => OutlinedButton(
                    key: anchorKey,
                    onPressed: () => showTransientError(
                      anchor,
                      _noSpeech,
                      errorKey: 'dictation/no-speech',
                      icon: Icons.mic_none,
                      severity: StudioErrorSeverity.noResult,
                      detail: _hint,
                    ),
                    child: const Text('Dictate a message'),
                  ),
                ),
              ],
            ),
          ),
        );
        final anchor = find.byKey(anchorKey);
        final before = tester.getRect(anchor);
        await tester.tap(anchor);
        await tester.pumpAndSettle();
        final bounds = tester.getRect(_floating());
        expect(tester.getRect(anchor), before);
        expect(bounds.bottom, closeTo(before.top - 28, 0.01));
        expect(bounds.width, lessThan(before.width));
        expect(bounds.width, lessThanOrEqualTo(340));
        expect(bounds.bottom, lessThan(700 - 210));
        expect(find.text(_hint), findsOneWidget);
        expect(find.byTooltip('Close'), findsNothing);
        expect(find.byTooltip('Retry'), findsNothing);
        final capsule = tester.element(_floating());
        expect(MediaQuery.textScalerOf(capsule).scale(14), 14 * scale);
        expect(MediaQuery.disableAnimationsOf(capsule), isTrue);
        expect(MediaQuery.viewInsetsOf(capsule).bottom, 210);
        final tokens = WingTokens.of(capsule);
        expect(
          tester.widget<Text>(find.text(_noSpeech)).style!.color,
          tokens.onSurface,
        );
        expect(
          tester.widget<Icon>(find.byIcon(Icons.mic_none)).color,
          tokens.warning,
        );
        expect(tester.takeException(), isNull);
        await _capture(tester, '${brightness.name}-$scale-keyboard');
        await tester.pump(const Duration(seconds: 4));
      });
    }
  }

  testWidgets('a suffix capsule clears a multiline draft and the keyboard', (
    tester,
  ) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    const draft = 'Draft stays here';
    await _show(
      tester,
      keyboard: 210,
      scale: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Spacer(),
            TextField(
              focusNode: focus,
              minLines: 4,
              maxLines: 4,
              decoration: InputDecoration(suffixIcon: _trigger('Dictate')),
            ),
          ],
        ),
      ),
    );
    final field = find.byType(InputDecorator);
    await tester.enterText(find.byType(TextField), draft);
    await tester.pumpAndSettle();
    final before = tester.getRect(field);
    final mic = find.byTooltip('Dictate');
    expect(tester.getRect(mic).top, greaterThan(before.top + 28));
    await tester.tap(mic);
    await tester.pumpAndSettle();

    final capsule = tester.getRect(_floating());
    expect(tester.getRect(field), before);
    expect(capsule.left, greaterThan(before.left));
    expect(capsule.right, lessThan(before.right));
    expect(capsule.bottom, closeTo(before.top - 28, 0.01));
    expect(capsule.bottom, lessThan(700 - 210));
    expect(focus.hasFocus, isTrue);
    expect(find.text(draft), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'multiline-2.0-keyboard');
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('same cause does not restart the four-second timer', (
    tester,
  ) async {
    await _show(
      tester,
      child: Column(
        children: [
          _trigger('First control'),
          _trigger('Second control', message: 'Duplicate symptom'),
          _trigger('Retry control', retryClears: true),
        ],
      ),
    );
    await tester.tap(find.byTooltip('First control'));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(find.text(_noSpeech), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.byTooltip('Second control'), warnIfMissed: false);
    await tester.pump();
    expect(find.text('Duplicate symptom'), findsNothing);
    await tester.pump(const Duration(milliseconds: 999));
    expect(_floating(), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(_floating(), findsNothing);
    await tester.tap(find.byTooltip('Second control'));
    await tester.pumpAndSettle();
    expect(_floating(), findsNothing);

    await tester.tap(find.byTooltip('Retry control'));
    await tester.pumpAndSettle();
    expect(_floating(), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('distinct causes coexist and a swipe clears only one', (
    tester,
  ) async {
    await _show(
      tester,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _trigger('First control'),
            _trigger(
              'Second control',
              message: 'Microphone unavailable',
              errorKey: 'dictation/microphone',
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.byTooltip('First control'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Second control'));
    await tester.pumpAndSettle();
    // Both fit, with one on either side of the controls.
    expect(_floating(), findsNWidgets(2));

    await tester.drag(
      find.text('Microphone unavailable'),
      const Offset(300, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('Microphone unavailable'), findsNothing);
    expect(find.text(_noSpeech), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('a newest cause takes the only clear area below the controls', (
    tester,
  ) async {
    await _show(
      tester,
      child: Row(
        children: [
          _trigger('First control'),
          _trigger(
            'Second control',
            message: 'Microphone unavailable',
            errorKey: 'dictation/microphone',
          ),
        ],
      ),
    );
    await tester.tap(find.byTooltip('First control'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Second control'));
    await tester.pumpAndSettle();
    expect(find.text(_noSpeech), findsNothing);
    final bounds = tester.getRect(_floating());
    final anchor = tester.getRect(find.byTooltip('Second control'));
    expect(bounds.top, closeTo(anchor.bottom + 28, 0.01));
    final semantics = tester.ensureSemantics();
    try {
      final dismissal = find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.onDismiss != null,
      );
      final node = tester.getSemantics(dismissal);
      expect(node.getSemanticsData().label, 'Microphone unavailable\n$_hint');
      expect(
        node.getSemanticsData().hasAction(ui.SemanticsAction.dismiss),
        isTrue,
      );
      node.owner!.performAction(node.id, ui.SemanticsAction.dismiss);
    } finally {
      semantics.dispose();
    }
    await tester.pumpAndSettle();
    expect(_floating(), findsNothing);
  });

  testWidgets('the timer starts even while its source keeps moving', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await _show(
      tester,
      child: ListView(
        controller: scroll,
        children: [
          const SizedBox(height: 400),
          Center(child: _trigger('Dictate')),
          const SizedBox(height: 600),
        ],
      ),
    );
    await tester.tap(find.byTooltip('Dictate'));
    for (var offset = 1.0; offset <= 3; offset++) {
      scroll.jumpTo(offset);
      await tester.pump();
    }
    expect(tester.getRect(_floating()).top, greaterThan(0));
    for (var offset = 4.0; offset <= 6; offset++) {
      scroll.jumpTo(offset);
      await tester.pump(const Duration(seconds: 1));
      expect(_floating(), findsOneWidget);
    }
    scroll.jumpTo(7);
    await tester.pump(const Duration(seconds: 1));
    expect(_floating(), findsNothing);
  });

  testWidgets('a scrolled-away trigger retires its notice without replay', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await _show(
      tester,
      child: Align(
        alignment: Alignment.center,
        child: SizedBox(
          height: 230,
          child: ListView(
            controller: scroll,
            children: [
              const SizedBox(height: 100),
              Center(child: _trigger('Dictate')),
              const SizedBox(height: 600),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Dictate'));
    await tester.pumpAndSettle();
    final before = tester.getRect(_floating());
    scroll.jumpTo(40);
    await tester.pumpAndSettle();
    expect(tester.getRect(_floating()).top, closeTo(before.top - 40, 0.01));
    scroll.jumpTo(220);
    await tester.pumpAndSettle();
    expect(_floating(), findsNothing);
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(_floating(), findsNothing);
  });

  testWidgets('route departure and background retire the current event', (
    tester,
  ) async {
    Object? error;
    var showControl = true;
    late StateSetter update;
    late BuildContext host;
    await _show(
      tester,
      child: StatefulBuilder(
        builder: (context, setState) {
          update = setState;
          host = context;
          if (!showControl) return const SizedBox.shrink();
          return Center(
            child: StudioTransientErrorAnchor(
              errorKey: error,
              message: error == null ? null : _noSpeech,
              child: IconButton(
                icon: const Icon(Icons.mic_none),
                tooltip: 'Dictate',
                onPressed: () => update(() => error = Object()),
              ),
            ),
          );
        },
      ),
    );
    final microphone = find.byTooltip('Dictate');
    await tester.tap(microphone);
    await tester.pumpAndSettle();
    expect(_floating(), findsOneWidget);
    Navigator.of(host).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Next')),
      ),
    );
    await tester.pumpAndSettle();
    expect(_floating(), findsNothing);
    Navigator.of(host).pop();
    await tester.pumpAndSettle();
    expect(_floating(), findsNothing);

    await tester.tap(microphone);
    await tester.pumpAndSettle();
    expect(_floating(), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(_floating(), findsNothing);

    await tester.tap(microphone);
    await tester.pumpAndSettle();
    expect(_floating(), findsOneWidget);
    update(() => showControl = false);
    await tester.pumpAndSettle();
    expect(_floating(), findsNothing);
    update(() => showControl = true);
    await tester.pumpAndSettle();
    expect(_floating(), findsNothing);

    await tester.tap(microphone);
    await tester.pumpAndSettle();
    expect(_floating(), findsOneWidget);
    update(() => error = null);
    await tester.pumpAndSettle();
    expect(_floating(), findsNothing);
  });
}
