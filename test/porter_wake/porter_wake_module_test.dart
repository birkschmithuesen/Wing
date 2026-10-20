import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/porter_wake/porter_wake_api.dart';
import 'package:wing/porter_wake/porter_wake_bridge.dart';
import 'package:wing/porter_wake/porter_wake_device_id.dart';
import 'package:wing/porter_wake/porter_wake_ledger.dart';
import 'package:wing/porter_wake/porter_wake_module.dart';

import 'fake_porter_bridge.dart';
import 'porter_wake_device_id_test.dart' show MemoryCredentialStore;
import 'porter_wake_fake_server.dart';

SavedConnection conn(String id) => SavedConnection(
  id: id, label: 'Home', host: 'hermes.test', port: 8642, apiKey: '');

class _GatedApi extends PorterWakeApi {
  _GatedApi(super.client, this.gate);
  final Future<void> gate;
  @override
  Future<PorterProbe> probe() async {
    await gate;
    return super.probe();
  }
}

void main() {
  late FakePorterServer server;
  late RecordingPorterWakeBridge bridge;
  late PorterWakeModule module;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    server = FakePorterServer();
    bridge = RecordingPorterWakeBridge();
    module = PorterWakeModule(
      bridge: bridge,
      deviceIds: PorterDeviceIdStore(store: MemoryCredentialStore()),
      ledger: PorterNoticeLedger(await SharedPreferences.getInstance()),
      apiFactory: (_) => PorterWakeApi(server.client()),
    );
    await module.start();
  });

  test('a 200 probe activates the connection and registers its instance', () async {
    await module.sync([conn('c1')]);
    expect(module.activeConnections.map((c) => c.id), ['c1']);
    expect(bridge.registered, ['c1']);
  });

  test('a 404 probe registers nothing and calls no other porter route', () async {
    server.statusFor['GET ${FakePorterServer.base}/settings/quiet-hours'] = 404;
    await module.sync([conn('c1')]);
    await module.sync([conn('c1')]);
    expect(module.activeConnections, isEmpty);
    expect(bridge.registered, isEmpty);
    expect(bridge.unregistered, ['c1']);
    expect(server.porterRequests().map((r) => '${r.method} ${r.url.path}'),
        ['GET ${FakePorterServer.base}/settings/quiet-hours']);
  });

  test('a 503 probe is treated like 404', () async {
    server.statusFor['GET ${FakePorterServer.base}/settings/quiet-hours'] = 503;
    await module.sync([conn('c1')]);
    expect(bridge.registered, isEmpty);
    expect(module.activeConnections, isEmpty);
  });

  test('a network failure leaves the connection unprobed for a later retry', () async {
    server.statusFor['GET ${FakePorterServer.base}/settings/quiet-hours'] = 500;
    await module.sync([conn('c1')]);
    expect(bridge.registered, isEmpty);
    server.statusFor.clear();
    await module.sync([conn('c1')]);
    expect(bridge.registered, ['c1']);
  });

  test('a new endpoint is posted with the stable device id and label', () async {
    await module.sync([conn('c1')]);
    await bridge.emit(const PorterEndpointEvent('c1', 'http://100.75.24.33:2586/upAbC123xyz?up=1'));
    await bridge.emit(const PorterEndpointEvent('c1', 'http://100.75.24.33:2586/upZZZ999zzz?up=1'));
    final posts = server.porterRequests().where((r) => r.method == 'POST').toList();
    expect(posts, hasLength(2));
    final first = jsonDecode(posts[0].body) as Map;
    final second = jsonDecode(posts[1].body) as Map;
    expect(first['device_id'], second['device_id']);
    expect(first['label'], 'Pixel 7');
    expect(second['endpoint'], 'http://100.75.24.33:2586/upZZZ999zzz?up=1');
  });

  test('an endpoint queued before the probe is posted once the probe succeeds', () async {
    await bridge.emit(const PorterEndpointEvent('c1', 'http://100.75.24.33:2586/upAbC123xyz?up=1'));
    expect(server.porterRequests(), isEmpty);
    await module.sync([conn('c1')]);
    final posts = server.porterRequests().where((r) => r.method == 'POST').toList();
    expect(posts, hasLength(1));
    expect((jsonDecode(posts.single.body) as Map)['endpoint'],
        'http://100.75.24.33:2586/upAbC123xyz?up=1');
  });

  test('an unregistration queued before the probe deletes the device once the probe succeeds', () async {
    await bridge.emit(const PorterUnregisteredEvent('c1'));
    await module.sync([conn('c1')]);
    expect(server.porterRequests().where((r) => r.method == 'DELETE'), hasLength(1));
  });

  test('events queued for a connection that probes inert are dropped', () async {
    server.statusFor['GET ${FakePorterServer.base}/settings/quiet-hours'] = 404;
    await bridge.emit(const PorterEndpointEvent('c1', 'http://100.75.24.33:2586/upAbC123xyz?up=1'));
    await module.sync([conn('c1')]);
    expect(server.porterRequests().where((r) => r.method != 'GET'), isEmpty);
  });

  test('a push after a failed startup probe re-probes and shows the full notice', () async {
    server.statusFor['GET ${FakePorterServer.base}/settings/quiet-hours'] = 500;
    await module.sync([conn('c1')]);
    expect(module.activeConnections, isEmpty);
    server.statusFor.clear();
    final bytes = Uint8List.fromList(
        utf8.encode(jsonEncode({'v': 1, 'type': 'porter_wake', 'notice_id': 'n-3f2a9c1b7d4e'})));
    await bridge.emit(PorterPushEvent('c1', bytes));
    expect(module.activeConnections.map((c) => c.id), ['c1']);
    expect(bridge.shown.single.neutral, isFalse);
  });

  test('an endpoint for an unknown connection after the first sync is ignored', () async {
    await module.sync([conn('c1')]);
    await bridge.emit(const PorterEndpointEvent('c9', 'http://100.75.24.33:2586/upAbC123xyz?up=1'));
    expect(server.porterRequests().where((r) => r.method != 'GET'), isEmpty);
  });

  test('forget deletes the device and unregisters', () async {
    await module.sync([conn('c1')]);
    await module.forget(conn('c1'));
    final delete = server.porterRequests().last;
    expect(delete.method, 'DELETE');
    expect(delete.url.path, startsWith('${FakePorterServer.base}/push/devices/wing-'));
    expect(bridge.unregistered, ['c1']);
    expect(module.activeConnections, isEmpty);
  });

  test('distributor unregistration deletes the device on the server', () async {
    await module.sync([conn('c1')]);
    await bridge.emit(const PorterUnregisteredEvent('c1'));
    expect(server.porterRequests().last.method, 'DELETE');
  });

  test('refresh re-probes and registers again', () async {
    await module.sync([conn('c1')]);
    await module.refresh(conn('c1'));
    expect(bridge.registered, ['c1', 'c1']);
  });

  test('a vanished connection is dropped from the active set', () async {
    await module.sync([conn('c1')]);
    await module.sync([]);
    expect(module.activeConnections, isEmpty);
  });

  test('a connection that vanishes from sync is revoked like forget', () async {
    await module.sync([conn('c1')]);
    await module.sync([]);
    final requests = server.porterRequests();
    expect(requests.where((r) => r.method == 'DELETE'), hasLength(1));
    expect(requests.last.url.path, startsWith('${FakePorterServer.base}/push/devices/wing-'));
    expect(bridge.unregistered, ['c1']);
    final count = requests.length;
    await module.sync([]);
    expect(server.porterRequests(), hasLength(count));
    expect(bridge.unregistered, ['c1']);
  });

  test('an inert or unknown vanished id is unregistered without a DELETE', () async {
    server.statusFor['GET ${FakePorterServer.base}/settings/quiet-hours'] = 404;
    await module.sync([conn('c1')]);
    server.statusFor['GET ${FakePorterServer.base}/settings/quiet-hours'] = 500;
    await module.sync([conn('c1'), conn('c2')]);
    bridge.unregistered.clear();
    await module.sync([]);
    expect(bridge.unregistered.toSet(), {'c1', 'c2'});
    expect(server.porterRequests().where((r) => r.method == 'DELETE'), isEmpty);
  });

  test('forget on an inactive connection still unregisters without a DELETE', () async {
    server.statusFor['GET ${FakePorterServer.base}/settings/quiet-hours'] = 500;
    await module.sync([conn('c1')]);
    await module.forget(conn('c1'));
    expect(bridge.unregistered, ['c1']);
    expect(server.porterRequests().where((r) => r.method == 'DELETE'), isEmpty);
  });

  test('refresh during an in-flight probe discards it and probes the new connection', () async {
    final gate = Completer<void>();
    final seen = <SavedConnection>[];
    final gated = PorterWakeModule(
      bridge: bridge,
      deviceIds: PorterDeviceIdStore(store: MemoryCredentialStore()),
      ledger: PorterNoticeLedger(await SharedPreferences.getInstance()),
      apiFactory: (c) {
        seen.add(c);
        return seen.length == 1
            ? _GatedApi(server.client(), gate.future)
            : PorterWakeApi(server.client());
      },
    );
    final first = gated.sync([conn('c1')]);
    final edited = SavedConnection(
        id: 'c1', label: 'Edited', host: 'hermes.test', port: 8642, apiKey: '');
    final refreshed = gated.refresh(edited);
    await refreshed;
    expect(gated.activeConnections.single.label, 'Edited');
    gate.complete();
    await first;
    await refreshed;
    expect(gated.activeConnections.single.label, 'Edited');
    expect(seen.map((c) => c.label), ['Home', 'Edited']);
    expect(bridge.registered, ['c1']);
  });

  test('forget during an in-flight probe never activates or registers it', () async {
    final gate = Completer<void>();
    final gated = PorterWakeModule(
      bridge: bridge,
      deviceIds: PorterDeviceIdStore(store: MemoryCredentialStore()),
      ledger: PorterNoticeLedger(await SharedPreferences.getInstance()),
      apiFactory: (_) => _GatedApi(server.client(), gate.future),
    );
    final probing = gated.sync([conn('c1')]);
    await gated.forget(conn('c1'));
    gate.complete();
    await probing;
    expect(gated.activeConnections, isEmpty);
    expect(bridge.registered, isEmpty);
  });

  test('the most recent pforte session wins', () {
    expect(mostRecentSessionId([
      {'id': 'old', 'last_active': 10},
      {'id': 'new', 'last_active': 30},
      {'id': 'mid', 'last_active': 20},
      {'id': 'broken'},
    ]), 'new');
    expect(mostRecentSessionId(const []), isNull);
  });
}
