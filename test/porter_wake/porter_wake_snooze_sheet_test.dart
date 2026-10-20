import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/porter_wake/porter_wake_notice.dart';
import 'package:wing/porter_wake/porter_wake_snooze_sheet.dart';

import 'porter_wake_fixtures.dart';

void main() {
  const capture = bool.fromEnvironment('VOICE_REVIEW');
  const frame = Key('porter-sheet-frame');
  setUpAll(() async {
    if (!capture) return;
    const path = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      'Roboto': ['Roboto-Regular.ttf'],
      'MaterialIcons': ['MaterialIcons-Regular.otf'],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final name in entry.value) {
        loader.addFont(Future.value(ByteData.sublistView(File('$path/$name').readAsBytesSync())));
      }
      await loader.load();
    }
  });

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(frame));
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build/voice-review').createSync(recursive: true);
      await File('build/voice-review/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  PorterNotice example() =>
      PorterNotice.fromJson(jsonDecode(porterExampleB) as Map<String, dynamic>);

  Future<void> open(
    WidgetTester tester, {
    required Future<bool> Function(Map<String, String>) feedback,
    Future<void> Function(String, String)? openItem,
    Brightness brightness = Brightness.light,
    double scale = 1,
    bool phone = false,
  }) async {
    if (phone) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 700);
      addTearDown(tester.view.reset);
    }
    await tester.pumpWidget(MaterialApp(
      theme: wingTheme(brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: RepaintBoundary(key: frame, child: child),
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showPorterNoticeSheet(
              context,
              notice: example(),
              feedback: feedback,
              openItem: openItem ?? (_, _) async {},
            ),
            child: const Text('go'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  testWidgets('long-press offers Später, in 2 Stunden and morgen and sends the value',
      (tester) async {
    final sent = <Map<String, String>>[];
    await open(tester, feedback: (body) async {
      sent.add(body);
      return true;
    });
    expect(find.text('🔴 3 Dinge warten'), findsOneWidget);
    expect(find.text('Buchhandlung Seewind: Lesungstermin bestätigen?'), findsOneWidget);
    await tester.longPress(find.text('Steuer: Konto für Erstattung bestätigen?'));
    await tester.pumpAndSettle();
    expect(find.text('Später'), findsOneWidget);
    expect(find.text('in 2 Stunden'), findsOneWidget);
    expect(find.text('morgen'), findsOneWidget);
    await tester.tap(find.text('in 2 Stunden'));
    await tester.pumpAndSettle();
    expect(sent, [
      {'action': 'snooze', 'value': '2h'},
    ]);
    expect(find.text('🔴 3 Dinge warten'), findsNothing);
  });

  testWidgets('the snooze button next to an item opens the same chooser', (tester) async {
    final sent = <Map<String, String>>[];
    await open(tester, feedback: (body) async {
      sent.add(body);
      return true;
    });
    await tester.tap(find.byTooltip('Snooze').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('morgen'));
    await tester.pumpAndSettle();
    expect(sent, [
      {'action': 'snooze', 'value': 'morgen'},
    ]);
  });

  testWidgets('Später sends the default value of the notice', (tester) async {
    final sent = <Map<String, String>>[];
    await open(tester, feedback: (body) async {
      sent.add(body);
      return true;
    });
    await tester.longPress(find.text('Steuer: Konto für Erstattung bestätigen?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Später'));
    await tester.pumpAndSettle();
    expect(sent, [
      {'action': 'snooze', 'value': 'default'},
    ]);
  });

  testWidgets('tapping an item opens its own session', (tester) async {
    final opened = <(String, String)>[];
    await open(
      tester,
      feedback: (_) async => true,
      openItem: (p, s) async => opened.add((p, s)),
    );
    await tester.tap(find.text('Zugangsdaten im Klartext in Notiz gefunden: löschen?'));
    await tester.pumpAndSettle();
    expect(opened, [('cothinker', 's-notiz')]);
    expect(find.text('🔴 3 Dinge warten'), findsNothing);
  });

  testWidgets('a failed snooze keeps the sheet and shows an error', (tester) async {
    await open(tester, feedback: (_) async => false, phone: true);
    await tester.longPress(find.text('Steuer: Konto für Erstattung bestätigen?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('morgen'));
    await tester.pumpAndSettle();
    expect(find.text('🔴 3 Dinge warten'), findsOneWidget);
    expect(find.text('Could not save. Try again.'), findsOneWidget);
    await screenshot(tester, 'porter-sheet-error-light');
  });

  testWidgets('pending snooze disables the rows until the server answers', (tester) async {
    final completer = Completer<bool>();
    final opened = <(String, String)>[];
    await open(
      tester,
      feedback: (_) => completer.future,
      openItem: (p, s) async => opened.add((p, s)),
      phone: true,
    );
    await tester.longPress(find.text('Steuer: Konto für Erstattung bestätigen?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('morgen'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await screenshot(tester, 'porter-sheet-pending-light');
    await tester.tap(find.text('Zugangsdaten im Klartext in Notiz gefunden: löschen?'));
    await tester.pump();
    expect(opened, isEmpty);
    completer.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('🔴 3 Dinge warten'), findsNothing);
  });

  testWidgets('sheet at 320 dp, light', (tester) async {
    await open(tester, feedback: (_) async => true, phone: true);
    expect(tester.takeException(), isNull);
    await screenshot(tester, 'porter-sheet-light');
  });

  testWidgets('chooser at 320 dp, dark', (tester) async {
    await open(tester, feedback: (_) async => true, brightness: Brightness.dark, phone: true);
    await tester.longPress(find.text('Steuer: Konto für Erstattung bestätigen?'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await screenshot(tester, 'porter-sheet-chooser-dark');
  });

  testWidgets('sheet at 200% text, light', (tester) async {
    await open(tester, feedback: (_) async => true, scale: 2, phone: true);
    expect(tester.takeException(), isNull);
    await screenshot(tester, 'porter-sheet-light-200');
  });

  testWidgets('sheet at 200% text, dark', (tester) async {
    await open(
      tester,
      feedback: (_) async => true,
      brightness: Brightness.dark,
      scale: 2,
      phone: true,
    );
    expect(tester.takeException(), isNull);
    await screenshot(tester, 'porter-sheet-dark-200');
  });

  testWidgets('chooser at 200% text, dark', (tester) async {
    await open(
      tester,
      feedback: (_) async => true,
      brightness: Brightness.dark,
      scale: 2,
      phone: true,
    );
    await tester.tap(find.byTooltip('Snooze').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('morgen'), findsOneWidget);
    await screenshot(tester, 'porter-sheet-chooser-dark-200');
  });
}
