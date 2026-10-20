import 'dart:async';

import 'package:wing/porter_wake/porter_wake_bridge.dart';
import 'package:wing/porter_wake/porter_wake_presentation.dart';

class RecordingPorterWakeBridge implements PorterWakeBridge {
  final shown = <PorterNotificationSpec>[];
  final registered = <String>[];
  final unregistered = <String>[];
  int cancels = 0;
  int finishes = 0;
  bool distributorAvailable = true;
  Future<bool> Function(PorterBridgeEvent)? onEvent;

  Future<bool> emit(PorterBridgeEvent event) => onEvent!(event);

  @override
  Future<void> start(Future<bool> Function(PorterBridgeEvent) onEvent,
      {required bool background}) async => this.onEvent = onEvent;
  @override
  Future<bool> register(String connectionId) async {
    registered.add(connectionId);
    return distributorAvailable;
  }
  @override
  Future<void> unregister(String connectionId) async => unregistered.add(connectionId);
  @override
  Future<void> show(PorterNotificationSpec spec) async => shown.add(spec);
  @override
  Future<void> cancel() async => cancels++;
  @override
  Future<String?> deviceLabel() async => 'Pixel 7';
  @override
  Future<void> finished() async => finishes++;
}
