import 'package:flutter_test/flutter_test.dart';
import 'package:wing/voice_offline/headphone_route.dart';
import '../support/headphone_route_fixture.dart';

void main() {
  group('classifyRoute (spec §3.4.1)', () {
    const cases = <(String, OutputRoute, bool, bool, String)>[
      ('wired headphones', OutputRoute(supported: true, type: 4), false, true, 'wired'),
      ('wired headset', OutputRoute(supported: true, type: 3), false, true, 'wired'),
      ('USB headset', OutputRoute(supported: true, type: 22), false, true, 'wired'),
      ('A2DP headphones', OutputRoute(supported: true, type: 8, bluetoothClass: 0x0418), false, true, 'bluetoothHeadphones'),
      ('A2DP headset', OutputRoute(supported: true, type: 8, bluetoothClass: 0x0404), false, true, 'bluetoothHeadphones'),
      ('LE headset', OutputRoute(supported: true, type: 26, bluetoothClass: 0x0404), false, true, 'bluetoothHeadphones'),
      ('car audio on A2DP', OutputRoute(supported: true, type: 8, bluetoothClass: 0x0420), false, false, 'bluetoothOther'),
      ('hands-free on A2DP', OutputRoute(supported: true, type: 8, bluetoothClass: 0x0408), false, false, 'bluetoothOther'),
      ('uncategorized A2DP', OutputRoute(supported: true, type: 8, bluetoothClass: 0x0400), false, false, 'bluetoothOther'),
      ('A2DP class unknown', OutputRoute(supported: true, type: 8), false, false, 'bluetoothClassUnknown'),
      ('LE headset class unknown', OutputRoute(supported: true, type: 26), false, false, 'bluetoothClassUnknown'),
      ('phone speaker', OutputRoute(supported: true, type: 2), false, false, 'speaker'),
      ('Bluetooth SCO', OutputRoute(supported: true, type: 7), false, false, 'other'),
      ('BLE speaker', OutputRoute(supported: true, type: 27), false, false, 'other'),
      ('Android 12 or older', OutputRoute.unknown, false, false, 'unsupported'),
      ('Android car mode', OutputRoute(supported: true, type: 4, androidCarMode: true), false, false, 'androidCarMode'),
      ('Wing car mode', OutputRoute(supported: true, type: 4), true, false, 'carMode'),
    ];
    for (final (name, route, carMode, headphones, reason) in cases) {
      test(name, () {
        final verdict = classifyRoute(route, wingCarMode: carMode);
        expect(verdict.headphones, headphones);
        expect(verdict.reason, reason);
      });
    }
  });

  test('the route log line carries numbers only', () {
    const bluetooth = OutputRoute(supported: true, type: 8, bluetoothClass: 0x0418);
    expect(
      routeLogLine(bluetooth, classifyRoute(bluetooth, wingCarMode: false)),
      'route headphones=1 reason=bluetoothHeadphones type=8 btClass=0x0418 androidCarMode=0',
    );
    const speaker = OutputRoute(supported: true, type: 2);
    expect(
      routeLogLine(speaker, classifyRoute(speaker, wingCarMode: false)),
      'route headphones=0 reason=speaker type=2 btClass=none androidCarMode=0',
    );
  });

  test('OutputRoute reads the channel map', () {
    final route = OutputRoute.fromMap({
      'supported': true,
      'type': 8,
      'bluetoothClass': 1048,
      'androidCarMode': false,
    });
    expect(route.supported, isTrue);
    expect(route.type, 8);
    expect(route.bluetoothClass, 0x0418);
    expect(OutputRoute.fromMap({}).supported, isFalse);
  });

  group('HeadphoneRoute', () {
    late HeadphoneRouteFixture host;
    late HeadphoneRoute route;
    var carMode = false;
    var notified = 0;

    setUp(() {
      host = HeadphoneRouteFixture();
      carMode = false;
      notified = 0;
      route = HeadphoneRoute(host, wingCarMode: () => carMode)
        ..addListener(() => notified++);
    });
    tearDown(() async {
      route.dispose();
      await host.close();
    });

    test('refresh reads the routed device', () async {
      host.route = HeadphoneRouteFixture.headphones;
      expect(await route.refresh(), isTrue);
      expect(route.headphones, isTrue);
      expect(notified, 1);
    });

    test('route changes close and reopen the verdict', () async {
      host.route = HeadphoneRouteFixture.headphones;
      await route.refresh();
      host.change(HeadphoneRouteFixture.speaker);
      expect(route.headphones, isFalse);
      host.change(HeadphoneRouteFixture.headphones);
      expect(route.headphones, isTrue);
      expect(notified, 3);
    });

    test('Wing car mode closes the verdict', () async {
      host.route = HeadphoneRouteFixture.headphones;
      await route.refresh();
      carMode = true;
      route.carModeChanged();
      expect(route.headphones, isFalse);
    });

    test('wired is true only for the wired reason, unlike headphones', () async {
      host.route = HeadphoneRouteFixture.headphones;
      await route.refresh();
      expect(route.headphones, isTrue);
      expect(route.wired, isTrue);
      host.change(
        const OutputRoute(supported: true, type: 8, bluetoothClass: 0x0418),
      );
      expect(route.headphones, isTrue);
      expect(route.wired, isFalse);
    });
  });
}
