import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/bots/bot_screen_view.dart';
import 'package:wing/core/services/bot_screen_session.dart';
import 'package:wing/core/models/transcript_message.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/services/bot_screen_window.dart';
import 'package:wing/core/widgets/bot_display_surface.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'support/bot_display_fixture.dart';

Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_BOT_SCREEN')) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('build/design-previews/bot-screen')
      ..createSync(recursive: true);
    await File(
      '${dir.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> ready(WidgetTester tester, BotScreenSession session) async {
  if (!session.connected) {
    final connected = Completer<void>();
    void observe() {
      if (session.connected && !connected.isCompleted) connected.complete();
    }

    session.addListener(observe);
    try {
      await tester.runAsync(() => connected.future);
    } finally {
      session.removeListener(observe);
    }
  }
  await tester.pump();
  // Pixel decoding runs in the engine outside the fake widget clock.
  for (var i = 0; i < 200; i++) {
    final images = tester.widgetList<RawImage>(find.byType(RawImage));
    if (images.any((image) => image.image != null)) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(BotScreenWindow.channel, (_) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(BotScreenWindow.channel, null),
    );
  });
  setUpAll(() async {
    if (!const bool.fromEnvironment('CAPTURE_BOT_SCREEN')) return;
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'monospace': 'build/studio-mono.ttf',
      'WingIcons': 'assets/fonts/wing-icons.ttf',
      'MaterialIcons':
          'build/design-previews/bot-screen/MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(entry.value).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'watch, touch, keyboard and hand-back: $brightness / $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final f = DisplayFixture();
          final bot = (await f.roster.repository.bots()).first;
          final session = BotScreenSession(f.repository, bot);
          final key = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(Brightness.light),
              darkTheme: wingTheme(Brightness.dark),
              themeMode: brightness == Brightness.dark
                  ? ThemeMode.dark
                  : ThemeMode.light,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(key: key, child: child!),
              ),
              home: BotScreenView(
                createSession: () => session,
                conversation: session,
                readConversation: () => [],
                readRequest: () =>
                    'Please finish signing in, then hand control back.',
                sendMessage: (_) async {},
              ),
            ),
          );
          await ready(tester, session);
          expect(find.byTooltip('Bot has control'), findsOneWidget);
          expect(f.calls.where((c) => c.$2.contains('lease.')), isEmpty);
          await capture(tester, key, 'watch-${brightness.name}-$scale');
          await tester.tap(find.byTooltip('More screen controls'));
          await tester.pump();
          for (final label in [
            'Zoom in',
            'Zoom out',
            'Fit screen',
            'Right click',
            'Double click',
          ]) {
            expect(find.byTooltip(label), findsNothing);
          }
          expect(find.byTooltip('Open conversation'), findsOneWidget);
          expect(find.byTooltip('Close screen'), findsOneWidget);
          await capture(tester, key, 'more-${brightness.name}-$scale');
          await tester.tap(find.byTooltip('More screen controls'));
          await tester.pump();
          await tester.tap(find.byTooltip('Take control'));
          await tester.pump();
          expect(find.byTooltip('You have control'), findsOneWidget);
          final raw = find.byType(RawImage);
          expect(raw, findsOneWidget);
          await tester.tap(raw);
          await tester.pump(const Duration(milliseconds: 100));
          expect(
            f.peers.single.sent.where((p) => p.length == 6 && p[1] == 1),
            isNotEmpty,
          );
          await tester.tap(find.byTooltip('Show keyboard'));
          await tester.pump();
          final field = find.byType(TextField);
          expect(tester.widget<TextField>(field).obscureText, true);
          final before = f.peers.single.sent.length;
          await tester.enterText(field, 'secure😀');
          await tester.pump();
          expect(f.peers.single.sent.length, greaterThan(before));
          expect(tester.widget<TextField>(field).controller!.text, '\u200b');
          final composingCount = f.peers.single.sent.length;
          tester.testTextInput.updateEditingValue(
            const TextEditingValue(
              text: '\u200bé',
              selection: TextSelection.collapsed(offset: 2),
              composing: TextRange(start: 1, end: 2),
            ),
          );
          await tester.pump();
          expect(f.peers.single.sent, hasLength(composingCount));
          tester.testTextInput.updateEditingValue(
            const TextEditingValue(
              text: '\u200bé',
              selection: TextSelection.collapsed(offset: 2),
            ),
          );
          await tester.pump();
          expect(f.peers.single.sent.length, composingCount + 2);
          expect(tester.widget<TextField>(field).controller!.text, '\u200b');
          await capture(tester, key, 'control-${brightness.name}-$scale');
          // A held poll renders loading while the keyboard is in use.
          final editing = tester.state(find.byType(EditableText));
          f.statusWait = Completer<void>();
          final refresh = session.refresh();
          await tester.pump();
          final during = tester.state(find.byType(EditableText));
          final focused = tester.widget<TextField>(field).focusNode!.hasFocus;
          f.statusWait!.complete();
          await refresh;
          await tester.pump();
          expect(during, same(editing));
          expect(tester.state(find.byType(EditableText)), same(editing));
          expect(focused, true);
          expect(field, findsOneWidget);
          await tester.tap(find.byTooltip('Hand control back'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Hand back'));
          await tester.pumpAndSettle();
          expect(find.byTooltip('Bot has control'), findsOneWidget);
          expect(find.byType(TextField), findsNothing);
          expect(f.holder, 'agent');
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
          expect(f.releases, 1);
        },
      );
    }
  }

  testWidgets(
    'zoomed touch coordinates and held dragging stay on the remote screen',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = DisplayFixture();
      final bot = (await f.roster.repository.bots()).first;
      final session = BotScreenSession(f.repository, bot);
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: BotScreenView(
            createSession: () => session,
            conversation: session,
            readConversation: () => [],
            readRequest: () =>
                'Please finish signing in, then hand control back.',
            sendMessage: (_) async {},
          ),
        ),
      );
      await ready(tester, session);
      await tester.tap(find.byTooltip('Take control'));
      await tester.pump();
      final surface = tester.widget<BotDisplaySurface>(
        find.byType(BotDisplaySurface),
      );
      final viewport = surface.viewport;
      viewport.zoom(2);
      await tester.pump();
      final surfaceBox = tester.renderObject<RenderBox>(
        find.byType(BotDisplaySurface),
      );
      final remote = const Offset(1, 1);
      final point = surfaceBox.localToGlobal(viewport.toLocal(remote));
      await tester.tapAt(point);
      await tester.pump(const Duration(milliseconds: 350));
      final packets = f.peers.single.sent;
      expect(packets.where((p) => p.length == 6 && p[0] == 5).last, [
        5,
        0,
        0,
        1,
        0,
        1,
      ]);
      final gesture = await tester.startGesture(point);
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveBy(Offset(viewport.scale, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      final pointers = packets
          .where((p) => p.length == 6 && p[0] == 5)
          .toList();
      expect(pointers.any((p) => p[1] == 1 && p[3] == 2), true);
      expect(pointers.last, [5, 0, 0, 2, 0, 1]);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('landscape and force hand-back require explicit confirmation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final f = DisplayFixture()
      ..holder = 'human'
      ..held = 'desktop-viewer';
    final bot = (await f.roster.repository.bots()).first;
    final session = BotScreenSession(f.repository, bot);
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.dark),
        home: BotScreenView(
          createSession: () => session,
          conversation: session,
          readConversation: () => [],
          readRequest: () =>
              'Please finish signing in, then hand control back.',
          sendMessage: (_) async {},
        ),
      ),
    );
    await ready(tester, session);
    expect(find.byTooltip('Human has control'), findsOneWidget);
    await tester.tap(find.byTooltip('More screen controls'));
    await tester.pump();
    await tester.tap(find.byTooltip('Hand control back (force)'));
    await tester.pumpAndSettle();
    expect(f.calls.where((c) => c.$3['force'] == true), isEmpty);
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(f.holder, 'human');
    await tester.tap(find.byTooltip('Hand control back (force)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Hand control back'));
    await tester.pumpAndSettle();
    expect(f.holder, 'agent');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
  testWidgets(
    'keyboard, fullscreen and rotation keep one viewer; local controls do not click desktop',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final f = DisplayFixture();
      final session = BotScreenSession(
        f.repository,
        (await f.roster.repository.bots()).first,
      );
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: RepaintBoundary(
            key: key,
            child: BotScreenView(
              createSession: () => session,
              conversation: session,
              readConversation: () => [],
              readRequest: () =>
                  'Please finish signing in, then hand control back.',
              sendMessage: (_) async {},
            ),
          ),
        ),
      );
      await ready(tester, session);
      await tester.tap(find.byTooltip('Take control'));
      await tester.pump();
      final v = tester
          .widget<BotDisplaySurface>(find.byType(BotDisplaySurface))
          .viewport;
      v.zoom(2);
      final pointers = f.peers.single.sent.where((p) => p[0] == 5).length;
      await tester.tap(find.byTooltip('More screen controls'));
      await tester.pump();
      await tester.tap(find.byTooltip('Enter fullscreen'));
      await tester.pump();
      expect(find.byType(AppBar), findsNothing);
      expect(f.peers, hasLength(1));
      expect(f.peers.single.sent.where((p) => p[0] == 5).length, pointers);
      await tester.tap(find.byTooltip('Show keyboard'));
      await tester.pump();
      session.setFocused(false);
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);
      session.setFocused(true);
      await tester.pump();
      final before = v.scale;
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pump();
      expect(v.scale, before);
      expect(tester.getSize(find.byType(TextField)).height, 1);
      await tester.tap(
        find.byType(BotDisplaySurface),
        kind: ui.PointerDeviceKind.mouse,
      );
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        true,
      );

      await tester.drag(find.byTooltip('Tab'), const Offset(-300, 0));
      await tester.pump();
      await tester.tap(find.byTooltip('More keyboard keys'));
      await tester.pump();
      await tester.tap(find.byTooltip('Control modifier'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      final keys = f.peers.single.sent.where((p) => p[0] == 4).toList();
      expect(keys.skip(keys.length - 4).map((p) => (p[1], p[6] * 256 + p[7])), [
        (1, 0xffe3),
        (1, 0xff08),
        (0, 0xff08),
        (0, 0xffe3),
      ]);
      await capture(tester, key, 'fullscreen-keyboard');
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(AppBar), findsNothing);
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(AppBar), findsOneWidget);
      expect(session.controlling, true);
      await tester.tap(find.byTooltip('More screen controls'));
      await tester.pump();
      await tester.tap(find.byTooltip('Enter fullscreen'));
      await tester.pump();
      await tester.tap(find.byTooltip('Show keyboard'));
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pump();
      // Android can update the IME inset before forwarding that same Back.
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(AppBar), findsNothing);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(AppBar), findsOneWidget);
      tester.view.physicalSize = const Size(844, 390);
      await tester.pump();
      expect(find.byType(AppBar), findsNothing);
      expect(f.peers, hasLength(1));
      expect(session.controlling, true);
      await capture(tester, key, 'fullscreen-landscape');
      await tester.tap(find.byTooltip('More screen controls'));
      await tester.pump();
      expect(find.byTooltip('Double click'), findsNothing);
      expect(find.byTooltip('Zoom in'), findsNothing);
      expect(find.byTooltip('Close screen'), findsOneWidget);
      await capture(tester, key, 'more-landscape');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(f.holder, 'agent');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('system overlay focus does not toggle immersive window bars', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final windows = <bool>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(BotScreenWindow.channel, (call) async {
          windows.add(call.arguments as bool);
          return null;
        });
    final f = DisplayFixture();
    final session = BotScreenSession(
      f.repository,
      (await f.roster.repository.bots()).first,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: BotScreenView(
          createSession: () => session,
          conversation: session,
          readConversation: () => [],
          readRequest: () =>
              'Please finish signing in, then hand control back.',
          sendMessage: (_) async {},
        ),
      ),
    );
    await ready(tester, session);
    expect(windows, [true]);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(windows, [true]);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(windows, [true]);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(windows.last, false);
  });
  testWidgets(
    'direct touch pinch zoom and two-finger wheel scrolling never produce both actions',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = DisplayFixture();
      final session = BotScreenSession(
        f.repository,
        (await f.roster.repository.bots()).first,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: BotScreenView(
            createSession: () => session,
            conversation: session,
            readConversation: () => [],
            readRequest: () =>
                'Please finish signing in, then hand control back.',
            sendMessage: (_) async {},
          ),
        ),
      );
      await ready(tester, session);
      await tester.tap(find.byTooltip('Take control'));
      await tester.pump();
      final v = tester
          .widget<BotDisplaySurface>(find.byType(BotDisplaySurface))
          .viewport;
      final point = tester.getCenter(find.byType(BotDisplaySurface));
      final before = v.scale;
      final count = f.peers.single.sent.where((p) => p[0] == 5).length;
      final a = await tester.startGesture(
        point - const Offset(50, 0),
        pointer: 1,
      );
      final b = await tester.startGesture(
        point + const Offset(50, 0),
        pointer: 2,
      );
      await tester.pump();
      await a.moveBy(const Offset(-40, 0));
      await b.moveBy(const Offset(40, 0));
      await tester.pump();
      await a.moveBy(const Offset(-20, 0));
      await b.moveBy(const Offset(20, 0));
      await tester.pump();
      await a.up();
      await b.up();
      await tester.pump();
      expect(v.scale, greaterThan(before));
      expect(f.peers.single.sent.where((p) => p[0] == 5).length, count);
      final zoom = v.scale;
      final c = await tester.startGesture(
        point - const Offset(50, 0),
        pointer: 3,
      );
      final d = await tester.startGesture(
        point + const Offset(50, 0),
        pointer: 4,
      );
      await tester.pump();
      for (var step = 0; step < 5; step++) {
        await c.moveBy(const Offset(0, -12));
        await d.moveBy(const Offset(0, -12));
        await tester.pump();
      }
      await c.up();
      await d.up();
      await tester.pump();
      expect(v.scale, zoom);
      expect(
        f.peers.single.sent.where((p) => p[0] == 5 && p[1] == 16),
        isNotEmpty,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
  testWidgets(
    'double-tap hold-drag keeps mouse down through movement and releases on lift',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = DisplayFixture();
      final session = BotScreenSession(
        f.repository,
        (await f.roster.repository.bots()).first,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: BotScreenView(
            createSession: () => session,
            conversation: session,
            readConversation: () => [],
            readRequest: () =>
                'Please finish signing in, then hand control back.',
            sendMessage: (_) async {},
          ),
        ),
      );
      await ready(tester, session);
      await tester.tap(find.byTooltip('Take control'));
      await tester.pump();
      final point = tester.getCenter(find.byType(BotDisplaySurface));
      await tester.tapAt(point);
      await tester.pump(const Duration(milliseconds: 100));
      final g = await tester.startGesture(point);
      await tester.pump(const Duration(milliseconds: 600));
      await g.moveBy(const Offset(80, 0));
      await tester.pump();
      final packets = f.peers.single.sent.where((p) => p[0] == 5).toList();
      expect(packets.last[1], 1);
      expect(packets.last[3], greaterThan(packets.first[3]));
      await g.up();
      await tester.pump();
      expect(f.peers.single.sent.where((p) => p[0] == 5).last[1], 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
  testWidgets('live agent context, direct paste progress and thumb scrolling', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final f = DisplayFixture();
    final session = BotScreenSession(
      f.repository,
      (await f.roster.repository.bots()).first,
    );
    final message = ValueNotifier('Please sign in.');
    final clipboard = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async =>
              call.method == 'Clipboard.getData' ? clipboard.future : null,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.light),
        home: BotScreenView(
          createSession: () => session,
          conversation: message,
          readConversation: () => [
            TranscriptMessage.fromRow({
              'role': 'assistant',
              'content': message.value,
            }),
          ],
          readRequest: () => null,
          sendMessage: (_) async {},
        ),
      ),
    );
    await ready(tester, session);
    expect(find.text('Please sign in.'), findsOneWidget);
    message.value = 'Choose the work account.';
    await tester.pump();
    expect(find.text('Choose the work account.'), findsOneWidget);
    await tester.tap(find.byTooltip('Take control'));
    await tester.pump();
    f.peers.single.requestClipboardOnPaste = false;
    final count = f.peers.single.sent.length;
    await tester.tap(find.byTooltip('Paste phone clipboard'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(StudioLoading), findsOneWidget);
    expect(find.byType(RawImage), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    clipboard.complete({'text': 'phone 😀\nclipboard'});
    await tester.pump();
    await tester.pump();
    expect(find.byType(StudioLoading), findsOneWidget);
    expect(find.text('Paste sent to the computer'), findsNothing);
    f.peers.single.requestClipboard();
    await tester.pump();
    await tester.pump();
    expect(
      f.peers.single.sent.skip(count).where((p) => p[0] == 6),
      hasLength(3),
    );
    expect(find.text('Paste sent to the computer'), findsOneWidget);
    await tester.pump();
    expect(find.byType(StudioLoading), findsNothing);
    await tester.drag(
      find.bySemanticsLabel('Scroll computer'),
      const Offset(0, 60),
    );
    await tester.pump();
    expect(
      f.peers.single.sent.where((p) => p[0] == 5 && p[1] == 16),
      isNotEmpty,
    );
    await tester.tap(find.byTooltip('Paste phone clipboard'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(StudioLoading), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(find.textContaining('Paste was not accepted'), findsOneWidget);
    expect(find.byType(StudioLoading), findsNothing);
    await tester.tap(find.byTooltip('More screen controls'));
    await tester.pump();
    f.statusWait = Completer<void>();
    await tester.tap(find.byTooltip('Refresh screen'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(StudioLoading), findsOneWidget);
    f.failStatus = true;
    f.statusWait!.complete();
    await tester.pump();
    await tester.pump();
    expect(
      find.textContaining('Screen connection could not be confirmed'),
      findsOneWidget,
    );
    await tester.pump();
    expect(find.byType(StudioLoading), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    message.dispose();
  });

  testWidgets(
    'handoff returns control before queueing and retains a failed note',
    (tester) async {
      final f = DisplayFixture();
      final session = BotScreenSession(
        f.repository,
        (await f.roster.repository.bots()).first,
      );
      final message = Completer<void>();
      var attempts = 0;
      final frame = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.light),
          home: RepaintBoundary(
            key: frame,
            child: BotScreenView(
              createSession: () => session,
              conversation: session,
              readConversation: () => [],
              readRequest: () => 'Sign in to continue.',
              sendMessage: (text) async {
                expect(f.holder, 'agent');
                expect(text, contains('Signed in'));
                attempts++;
                await message.future;
              },
            ),
          ),
        ),
      );
      await ready(tester, session);
      await tester.tap(find.byTooltip('Take control'));
      await tester.pump();
      await tester.tap(find.byTooltip('Hand control back'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Signed in');
      await capture(tester, frame, 'handoff-note');
      await tester.tap(find.byTooltip('Hand back'));
      await tester.pump();
      expect(f.holder, 'agent');
      expect(attempts, 1);
      await tester.pump();
      expect(find.byType(StudioLoading), findsOneWidget);
      message.completeError(StateError('offline'));
      await tester.pump();
      expect(
        find.textContaining('Control returned, but the message'),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Signed in',
      );
      expect(find.byTooltip('Retry message'), findsOneWidget);
      await tester.pump();
      expect(find.byType(StudioLoading), findsNothing);
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
  for (final brightness in Brightness.values) {
    for (final landscape in [false, true]) {
      testWidgets(
        'small phone keyboard and overlays ${brightness.name} $landscape',
        (tester) async {
          tester.view.physicalSize = landscape
              ? const Size(844, 390)
              : const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetViewInsets);
          final f = DisplayFixture();
          final session = BotScreenSession(
            f.repository,
            (await f.roster.repository.bots()).first,
          );
          final frame = GlobalKey();
          final notes = <String>[];
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: RepaintBoundary(key: frame, child: child!),
              ),
              home: BotScreenView(
                createSession: () => session,
                conversation: session,
                readConversation: () => [
                  TranscriptMessage.fromRow({
                    'role': 'assistant',
                    'content': 'Please finish signing in, then hand back.',
                  }),
                ],
                readRequest: () => null,
                sendMessage: (text) async => notes.add(text),
              ),
            ),
          );
          await ready(tester, session);
          await tester.tap(find.byTooltip('Take control'));
          await tester.pump();
          await tester.tap(find.byTooltip('Show keyboard'));
          await tester.pump();
          tester.view.viewInsets = FakeViewPadding(
            bottom: landscape ? 170 : 300,
          );
          await tester.pump();
          await tester.tap(find.byTooltip('More keyboard keys'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(tester.takeException(), isNull);
          await capture(
            tester,
            frame,
            'small-keyboard-${brightness.name}-$landscape',
          );
          await tester.tap(find.byTooltip('Hide keyboard'));
          tester.view.viewInsets = FakeViewPadding.zero;
          await tester.pump();
          await tester.tap(find.byTooltip('Open conversation'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), 'Signed in');
          tester.view.viewInsets = FakeViewPadding(
            bottom: landscape ? 170 : 300,
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(tester.takeException(), isNull);
          await capture(
            tester,
            frame,
            'conversation-${brightness.name}-$landscape',
          );
          await tester.tap(find.byTooltip('Send message to agent'));
          await tester.pump();
          expect(notes, ['Signed in']);
          expect(session.controlling, true);
          await tester.tap(find.byTooltip('Close conversation'));
          tester.view.viewInsets = FakeViewPadding.zero;
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Hand control back'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), 'All done');
          tester.view.viewInsets = FakeViewPadding(
            bottom: landscape ? 170 : 300,
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(tester.takeException(), isNull);
          await capture(tester, frame, 'handoff-${brightness.name}-$landscape');
          await tester.tap(find.byTooltip('Cancel'));
          tester.view.viewInsets = FakeViewPadding.zero;
          await tester.pumpAndSettle();
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        },
      );
    }
  }
  testWidgets('uninstalled screen retains the stock setup command', (
    tester,
  ) async {
    final f = DisplayFixture()
      ..running = false
      ..installed = false;
    final session = BotScreenSession(
      f.repository,
      (await f.roster.repository.bots()).first,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: BotScreenView(
          createSession: () => session,
          conversation: session,
          readConversation: () => [],
          readRequest: () => null,
          sendMessage: null,
        ),
      ),
    );
    await tester.pump();
    expect(
      find.text('sudo apt install tigervnc-standalone-server'),
      findsOneWidget,
    );
    expect(session.canStart, false);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
