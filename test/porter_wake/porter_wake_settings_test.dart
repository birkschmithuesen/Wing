import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/compact_switch.dart';
import 'package:wing/porter_wake/porter_wake_api.dart';
import 'package:wing/porter_wake/porter_wake_device_id.dart';
import 'package:wing/porter_wake/porter_wake_ledger.dart';
import 'package:wing/porter_wake/porter_wake_module.dart';
import 'package:wing/porter_wake/porter_wake_settings.dart';

import 'fake_porter_bridge.dart';
import 'porter_wake_device_id_test.dart' show MemoryCredentialStore;
import 'porter_wake_fake_server.dart';

void main() {
  const capture = bool.fromEnvironment('VOICE_REVIEW');
  const frame = Key('porter-frame');
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

  late FakePorterServer server;

  Future<PorterWakeModule> module({int probe = 200}) async {
    SharedPreferences.setMockInitialValues({});
    if (probe != 200) {
      server.statusFor['GET ${FakePorterServer.base}/settings/quiet-hours'] = probe;
    }
    final m = PorterWakeModule(
      bridge: RecordingPorterWakeBridge(),
      deviceIds: PorterDeviceIdStore(store: MemoryCredentialStore()),
      ledger: PorterNoticeLedger(await SharedPreferences.getInstance()),
      apiFactory: (_) => PorterWakeApi(server.client()),
    );
    await m.start();
    await m.sync([SavedConnection(id: 'c1', label: 'Home', host: 'hermes.test', port: 8642, apiKey: '')]);
    server.statusFor.clear();
    return m;
  }

  Future<void> pump(WidgetTester tester, PorterWakeModule m,
      {Brightness brightness = Brightness.light, double scale = 1}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 700);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: wingTheme(brightness),
      home: RepaintBoundary(
        key: frame,
        child: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(size: const Size(320, 700), textScaler: TextScaler.linear(scale)),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Card(child: PorterWakeSettings(module: m)),
            ),
          ),
        ),
      ),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  setUp(() => server = FakePorterServer());

  testWidgets('Nachtruhe shows the server values', (tester) async {
    final m = await tester.runAsync(() => module());
    await pump(tester, m!);
    expect(find.text('Nachtruhe'), findsOneWidget);
    expect(find.text('von'), findsOneWidget);
    expect(find.text('bis'), findsOneWidget);
    expect(find.text('22:00'), findsOneWidget);
    expect(find.text('08:00'), findsOneWidget);
    expect(find.text('Europe/Berlin'), findsOneWidget);
    await screenshot(tester, 'porter-nachtruhe-light');
  });

  testWidgets('Nachtruhe is hidden when the module is inactive', (tester) async {
    final m = await tester.runAsync(() => module(probe: 404));
    await pump(tester, m!);
    expect(find.text('Nachtruhe'), findsNothing);
  });

  testWidgets('toggling sends the full PUT and shows the 200 body', (tester) async {
    final m = await tester.runAsync(() => module());
    await pump(tester, m!);
    await tester.tap(find.text('Nachtruhe'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    final put = server.porterRequests().last;
    expect(put.method, 'PUT');
    expect(put.body, '{"enabled":false,"from":"22:00","to":"08:00"}');
  });

  testWidgets('a rejected save reverts and shows the server error', (tester) async {
    final m = await tester.runAsync(() => module());
    server.statusFor['PUT ${FakePorterServer.base}/settings/quiet-hours'] = 409;
    server.bodyFor['PUT ${FakePorterServer.base}/settings/quiet-hours'] =
        {'error': 'config layout not editable'};
    await pump(tester, m!);
    await tester.tap(find.text('Nachtruhe'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('config layout not editable'), findsOneWidget);
    final toggle = tester.widget<CompactSwitchListTile>(find.byType(CompactSwitchListTile));
    expect(toggle.value, isTrue);
    await screenshot(tester, 'porter-nachtruhe-error');
  });

  testWidgets('dark theme at 200% text keeps every control reachable', (tester) async {
    final m = await tester.runAsync(() => module());
    await pump(tester, m!, brightness: Brightness.dark, scale: 2);
    expect(tester.takeException(), isNull);
    expect(find.text('bis'), findsOneWidget);
    await screenshot(tester, 'porter-nachtruhe-dark-200');
  });
}
