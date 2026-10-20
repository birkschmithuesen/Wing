import 'dart:async';

import 'package:wing/voice_offline/headphone_route.dart';

class HeadphoneRouteFixture implements HeadphoneRouteHost {
  static const speaker = OutputRoute(supported: true, type: 2);
  static const headphones = OutputRoute(supported: true, type: 4);

  /// A2DP device, class `AUDIO_VIDEO_HEADPHONES` (e.g. a Sony WH-1000XM4).
  static const bluetoothHeadphones = OutputRoute(
    supported: true,
    type: 8,
    bluetoothClass: 0x0418,
  );

  /// A2DP device whose class is not a recognised headphone/headset
  /// (e.g. a car kit).
  static const bluetoothOther = OutputRoute(
    supported: true,
    type: 8,
    bluetoothClass: 0x0408,
  );

  OutputRoute route = speaker;
  bool allowed = true;
  bool grant = true;
  int requests = 0;
  final _changes = StreamController<OutputRoute>.broadcast(sync: true);

  @override
  Stream<OutputRoute> get changes => _changes.stream;

  @override
  Future<OutputRoute> current() async => route;

  @override
  Future<bool> bluetoothAllowed() async => allowed;

  @override
  Future<bool> requestBluetooth() async {
    requests++;
    allowed = grant;
    return grant;
  }

  /// Simulates plugging in, unplugging or a Bluetooth change.
  void change(OutputRoute next) {
    route = next;
    _changes.add(next);
  }

  Future<void> close() => _changes.close();
}
