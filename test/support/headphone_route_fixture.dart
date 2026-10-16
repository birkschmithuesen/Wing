import 'dart:async';

import 'package:wing/voice_offline/headphone_route.dart';

class HeadphoneRouteFixture implements HeadphoneRouteHost {
  static const speaker = OutputRoute(supported: true, type: 2);
  static const headphones = OutputRoute(supported: true, type: 4);

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
