import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'barge_in_policy.dart';

/// Raw facts about the device Android routes read-aloud to (the attributes
/// of VoicePlayback.kt: USAGE_MEDIA, CONTENT_TYPE_SPEECH). [type] is an
/// AudioDeviceInfo.TYPE_* value, [bluetoothClass] a BluetoothClass.Device
/// code. Dart decides what counts as headphones ([classifyRoute]).
class OutputRoute {
  const OutputRoute({
    required this.supported,
    required this.type,
    this.bluetoothClass,
    this.androidCarMode = false,
  });

  factory OutputRoute.fromMap(Map<Object?, Object?> map) => OutputRoute(
    supported: map['supported'] == true,
    type: (map['type'] as num?)?.toInt() ?? 0,
    bluetoothClass: (map['bluetoothClass'] as num?)?.toInt(),
    androidCarMode: map['androidCarMode'] == true,
  );

  /// Android 12 or older, or the query failed.
  static const unknown = OutputRoute(supported: false, type: 0);

  final bool supported;
  final int type;

  /// Null when Android does not let Wing read it (no Nearby devices access,
  /// anonymised address, Bluetooth off) or the device is not Bluetooth.
  final int? bluetoothClass;
  final bool androidCarMode;
}

typedef RouteVerdict = ({bool headphones, String reason});

const _wired = {3, 4, 22}; // WIRED_HEADSET, WIRED_HEADPHONES, USB_HEADSET
const _bluetooth = {8, 26}; // BLUETOOTH_A2DP, BLE_HEADSET
const _speaker = 2; // BUILTIN_SPEAKER
const _headphoneClasses = {0x0404, 0x0418}; // WEARABLE_HEADSET, HEADPHONES

/// Spec §3.4.1 (D2): voice barge-in into read-aloud only with headphones.
/// Conservative: a car kit, a hands-free unit or an unreadable Bluetooth
/// class is not headphones, and car mode always closes the gate.
RouteVerdict classifyRoute(OutputRoute route, {required bool wingCarMode}) {
  if (!route.supported) return (headphones: false, reason: 'unsupported');
  if (wingCarMode) return (headphones: false, reason: 'carMode');
  if (route.androidCarMode) {
    return (headphones: false, reason: 'androidCarMode');
  }
  if (_wired.contains(route.type)) return (headphones: true, reason: 'wired');
  if (_bluetooth.contains(route.type)) {
    final deviceClass = route.bluetoothClass;
    if (deviceClass == null) {
      return (headphones: false, reason: 'bluetoothClassUnknown');
    }
    return _headphoneClasses.contains(deviceClass)
        ? (headphones: true, reason: 'bluetoothHeadphones')
        : (headphones: false, reason: 'bluetoothOther');
  }
  return (
    headphones: false,
    reason: route.type == _speaker ? 'speaker' : 'other',
  );
}

/// Numbers and states only: never an address or a device name.
String routeLogLine(OutputRoute route, RouteVerdict verdict) {
  final deviceClass = route.bluetoothClass;
  final btClass = deviceClass == null
      ? 'none'
      : '0x${deviceClass.toRadixString(16).padLeft(4, '0')}';
  return 'route headphones=${verdict.headphones ? 1 : 0} '
      'reason=${verdict.reason} type=${route.type} btClass=$btClass '
      'androidCarMode=${route.androidCarMode ? 1 : 0}';
}

/// Native side of the route check (HeadphoneRouteChannel.kt).
abstract interface class HeadphoneRouteHost {
  Future<OutputRoute> current();

  /// Fires on every audio device added or removed.
  Stream<OutputRoute> get changes;

  /// Wing may read Bluetooth classes (always true below Android 12).
  Future<bool> bluetoothAllowed();

  /// Asks for Nearby devices access; resolves to whether Wing has it.
  Future<bool> requestBluetooth();
}

class AndroidHeadphoneRouteHost implements HeadphoneRouteHost {
  AndroidHeadphoneRouteHost._() {
    _channel.setMethodCallHandler((call) async {
      final args = call.arguments;
      if (call.method == 'changed' && args is Map) {
        _changes.add(OutputRoute.fromMap(args));
      }
    });
  }

  static final instance = AndroidHeadphoneRouteHost._();
  static const _channel = MethodChannel('com.tarkilhk.wing/headphone_route');
  final _changes = StreamController<OutputRoute>.broadcast();

  @override
  Stream<OutputRoute> get changes => _changes.stream;

  @override
  Future<OutputRoute> current() async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('current');
      return map == null ? OutputRoute.unknown : OutputRoute.fromMap(map);
    } on Object {
      return OutputRoute.unknown;
    }
  }

  @override
  Future<bool> bluetoothAllowed() async {
    try {
      return await _channel.invokeMethod<bool>('bluetoothAllowed') ?? true;
    } on Object {
      return true;
    }
  }

  @override
  Future<bool> requestBluetooth() async {
    try {
      return await _channel.invokeMethod<bool>('requestBluetooth') ?? false;
    } on Object {
      return false;
    }
  }
}

/// Cached headphone verdict: the playback decision in the workspace screen
/// is synchronous. Logs one `route` line whenever the inputs change.
class HeadphoneRoute extends ChangeNotifier {
  HeadphoneRoute(this.host, {required bool Function() wingCarMode})
    : _wingCarMode = wingCarMode {
    _changes = host.changes.listen(_apply);
  }

  final HeadphoneRouteHost host;
  final bool Function() _wingCarMode;
  late final StreamSubscription<OutputRoute> _changes;
  OutputRoute _route = OutputRoute.unknown;
  bool _headphones = false;
  String? _logged;
  bool _disposed = false;

  bool get headphones => _headphones;

  Future<bool> refresh() async {
    _apply(await host.current());
    return _headphones;
  }

  /// Wing car mode switched on or off; re-evaluate the last route.
  void carModeChanged() => _apply(_route);

  void _apply(OutputRoute route) {
    if (_disposed) return;
    _route = route;
    final verdict = classifyRoute(route, wingCarMode: _wingCarMode());
    final line = routeLogLine(route, verdict);
    if (line != _logged) {
      _logged = line;
      bargeLog(line);
    }
    if (verdict.headphones == _headphones) return;
    _headphones = verdict.headphones;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_changes.cancel());
    super.dispose();
  }
}
