import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:wing/core/config/support_wing.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/support_wing_section.dart';

// Uses the configured destination with a fake launcher; makes no network calls.
final _destinations = [
  (
    label: 'Sponsor on GitHub',
    platform: 'GitHub Sponsors',
    uri: wingGitHubSponsorsUri,
  ),
  (label: 'Buy me a coffee', platform: 'Ko-fi', uri: wingKoFiUri),
];
Finder _row(String label) => find.widgetWithText(ListTile, label);
const _frame = Key('support-frame');
const _capture = bool.fromEnvironment('CAPTURE_SUPPORT');

class _Browser extends UrlLauncherPlatform {
  final calls = <(String, LaunchOptions)>[];
  Future<bool> Function() result = () async => true;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) {
    calls.add((url, options));
    return result();
  }
}

Future<void> _show(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  double scale = 1,
  bool reducedMotion = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: wingTheme(brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: reducedMotion,
        ),
        child: child!,
      ),
      home: RepaintBoundary(
        key: _frame,
        child: Scaffold(
          appBar: AppBar(title: const Text('App settings')),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(WingSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'About',
                  style: wingTheme(brightness).textTheme.titleMedium,
                ),
                const SizedBox(height: WingSpacing.md),
                Card(
                  child: SupportWingSection(
                    githubUri: wingGitHubSponsorsUri,
                    koFiUri: wingKoFiUri,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _captureFrame(WidgetTester tester, String name) async {
  if (!_capture) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_frame),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory('build/support-review').createSync(recursive: true);
    File(
      'build/support-review/$name.png',
    ).writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  late UrlLauncherPlatform original;
  late _Browser browser;

  setUpAll(() async {
    const directory = String.fromEnvironment('CAPTURE_FONT_DIR');
    if (directory.isEmpty) return;
    for (final entry in {
      'Roboto': ['Roboto-Regular.ttf', 'Roboto-Medium.ttf'],
      'MaterialIcons': ['MaterialIcons-Regular.otf'],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final name in entry.value) {
        loader.addFont(
          Future.value(
            ByteData.sublistView(File('$directory/$name').readAsBytesSync()),
          ),
        );
      }
      await loader.load();
    }
  });

  setUp(() {
    original = UrlLauncherPlatform.instance;
    browser = _Browser();
    UrlLauncherPlatform.instance = browser;
  });
  tearDown(() => UrlLauncherPlatform.instance = original);

  for (final destination in _destinations) {
    testWidgets('${destination.platform} opens only on request, externally', (
      tester,
    ) async {
      await _show(tester);
      expect(browser.calls, isEmpty);
      await tester.tap(_row(destination.label));
      await tester.pumpAndSettle();
      expect(browser.calls.single.$1, destination.uri.toString());
      final options = browser.calls.single.$2;
      expect(options.mode, PreferredLaunchMode.externalApplication);
      expect(options.webViewConfiguration.headers, isEmpty);
    });

    for (final throws in [false, true]) {
      testWidgets(
        '${destination.platform} failure (throws: $throws) allows retry',
        (tester) async {
          browser.result = () async {
            if (throws) throw PlatformException(code: 'ACTIVITY_NOT_FOUND');
            return false;
          };
          await _show(tester);
          await tester.tap(_row(destination.label));
          await tester.pumpAndSettle();
          expect(
            find.textContaining('Could not open your browser.'),
            findsOneWidget,
          );
          expect(
            find.widgetWithText(SelectableText, destination.uri.toString()),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          browser.result = () async => true;
          await tester.tap(_row(destination.label));
          await tester.pumpAndSettle();
          expect(browser.calls.map((call) => call.$1), [
            destination.uri.toString(),
            destination.uri.toString(),
          ]);
          expect(
            find.textContaining('Could not open your browser.'),
            findsNothing,
          );
        },
      );
    }
  }

  testWidgets('choosing another provider replaces the failed destination', (
    tester,
  ) async {
    browser.result = () async => false;
    await _show(tester);
    await tester.tap(_row(_destinations.first.label));
    await tester.pumpAndSettle();
    final pending = Completer<bool>();
    browser.result = () => pending.future;
    await tester.tap(_row(_destinations.last.label));
    await tester.pump();
    expect(find.byType(SelectableText), findsNothing);
    pending.complete(false);
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(SelectableText, wingKoFiUri.toString()),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(SelectableText, wingGitHubSponsorsUri.toString()),
      findsNothing,
    );
  });

  testWidgets('pending launch prevents duplicates and tolerates leaving', (
    tester,
  ) async {
    final pending = Completer<bool>();
    browser.result = () => pending.future;
    await _show(tester);
    final before = tester.getRect(_row(_destinations.first.label));
    await tester.tap(_row(_destinations.first.label));
    await tester.pump();
    expect(tester.getRect(_row(_destinations.first.label)), before);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      find.descendant(
        of: _row(_destinations.first.label),
        matching: find.byIcon(Icons.favorite_border),
      ),
      findsOneWidget,
    );
    for (final destination in _destinations) {
      expect(tester.widget<ListTile>(_row(destination.label)).onTap, isNull);
      await tester.tap(_row(destination.label));
    }
    expect(browser.calls, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    pending.complete(false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('browser launch feedback $brightness at ${scale}x', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 740);
        addTearDown(tester.view.reset);
        final semantics = tester.ensureSemantics();
        var pending = Completer<bool>();
        addTearDown(() {
          if (!pending.isCompleted) pending.complete(false);
        });
        browser.result = () => pending.future;
        try {
          await _show(
            tester,
            brightness: brightness,
            scale: scale,
            reducedMotion: scale == 2,
          );
          final row = _row(_destinations.first.label);
          await tester.ensureVisible(row);
          await tester.pumpAndSettle();
          final before = tester.getRect(row);
          await tester.tap(row);
          await tester.pump();
          final progress = find.descendant(
            of: row,
            matching: find.byType(CircularProgressIndicator),
          );
          expect(progress, findsOneWidget);
          expect(tester.getSize(progress).shortestSide, greaterThan(0));
          expect(before.contains(tester.getCenter(progress)), isTrue);
          expect(tester.getRect(row), before);
          expect(
            find.bySemanticsLabel(RegExp('Opening GitHub Sponsors')),
            findsOneWidget,
          );
          await tester.pump(const Duration(milliseconds: 250));
          await _captureFrame(tester, '${brightness.name}-$scale-pending');
          await tester.tap(row);
          expect(browser.calls, hasLength(1));
          pending.complete(false);
          await tester.pumpAndSettle();
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(
            find.textContaining('Could not open your browser.'),
            findsOneWidget,
          );
          pending = Completer<bool>();
          await tester.ensureVisible(row);
          await tester.pumpAndSettle();
          await tester.tap(row);
          await tester.pump();
          expect(progress, findsOneWidget);
          expect(
            find.textContaining('Could not open your browser.'),
            findsNothing,
          );
          expect(browser.calls, hasLength(2));
          pending.complete(true);
          await tester.pumpAndSettle();
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(
            find.textContaining('Could not open your browser.'),
            findsNothing,
          );
          expect(tester.widget<ListTile>(row).onTap, isNotNull);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('accessible $brightness support at ${scale}x and 320dp', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 740);
        addTearDown(tester.view.reset);
        final semantics = tester.ensureSemantics();
        try {
          await _show(tester, brightness: brightness, scale: scale);
          expect(tester.takeException(), isNull);
          expect(find.text('Support Wing'), findsOneWidget);
          expect(
            find.text(
              'If Wing is useful in your day, you can buy me a coffee and help me keep improving it.',
            ),
            findsOneWidget,
          );
          expect(
            find.text(
              'Completely optional. Every feature is available either way.',
            ),
            findsOneWidget,
          );
          await _captureFrame(tester, '${brightness.name}-$scale-top');
          for (final destination in _destinations) {
            // Large text can place the actions below the viewport.
            await tester.ensureVisible(_row(destination.label));
            await tester.pumpAndSettle();
            expect(
              tester.getSemantics(_row(destination.label)),
              matchesSemantics(
                label: destination.label,
                hint: 'Opens ${destination.platform} in your browser',
                isButton: true,
                isEnabled: true,
                hasEnabledState: true,
                hasSelectedState: true,
                isFocusable: true,
                hasTapAction: true,
                hasFocusAction: true,
              ),
            );
            await expectLater(
              tester,
              meetsGuideline(androidTapTargetGuideline),
            );
            await expectLater(
              tester,
              meetsGuideline(labeledTapTargetGuideline),
            );
            await expectLater(tester, meetsGuideline(textContrastGuideline));
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(browser.calls.last.$1, destination.uri.toString());
          }
          expect(browser.calls, hasLength(2));
          await _captureFrame(tester, '${brightness.name}-$scale-actions');
          browser.result = () async => false;
          await tester.tap(_row(_destinations.last.label));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.byType(SelectableText));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await _captureFrame(tester, '${brightness.name}-$scale-error');
        } finally {
          semantics.dispose();
        }
      });
    }
  }
}
