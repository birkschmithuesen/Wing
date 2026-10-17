import 'package:wing/core/services/connection_manager.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/server_connection_status.dart';

void main() {
  test('a failed recovery stays visible until its owner retries or leaves', () {
    final status = ServerConnectionStatus('Claw');
    addTearDown(status.dispose);
    status.accessAvailable();
    status.liveChanged('default', true);
    status.failRecovery('notification', 'Chat could not be reopened');
    status.accessAvailable();
    status.endRecovery('another-profile');
    expect(status.phase, ServerConnectionPhase.disconnected);
    expect(status.problem, 'Chat could not be reopened');
    status.beginRecovery('notification');
    expect(status.phase, ServerConnectionPhase.reconnecting);
    expect(status.problem, isNull);
    status.endRecovery('notification');
    expect(status.phase, ServerConnectionPhase.connected);
  });

  test('server access and live chat are independent observations', () async {
    final status = ServerConnectionStatus('Claw');
    addTearDown(status.dispose);
    expect(status.phase, ServerConnectionPhase.unchecked);
    status.accessAvailable();
    status.liveChanged('travel', true);
    expect(status.phase, ServerConnectionPhase.connected);
    status.beginRecovery('travel');
    status.liveChanged('travel', false);
    expect(status.phase, ServerConnectionPhase.reconnecting);
    status.endRecovery('travel');
    expect(status.phase, ServerConnectionPhase.limited);
    expect(status.description, 'Live updates interrupted');
    await status.observeAccess(() async => 'admin works');
    expect(status.phase, ServerConnectionPhase.limited);
    status.accessFailed(const SocketException('private.host'));
    expect(status.phase, ServerConnectionPhase.disconnected);
    expect(status.problem, isNull);
    status.beginRecovery('travel');
    status.accessAvailable();
    status.liveChanged('travel', true);
    expect(status.phase, ServerConnectionPhase.reconnecting);
    status.endRecovery('travel');
    expect(status.phase, ServerConnectionPhase.connected);
  });

  test('recoveries from different profiles cannot clear each other', () {
    final status = ServerConnectionStatus('Claw');
    addTearDown(status.dispose);
    status.beginRecovery('first');
    status.beginRecovery('second');
    status.accessFailed(TimeoutException('private endpoint'));
    status.endRecovery('first');
    expect(status.phase, ServerConnectionPhase.reconnecting);
    status.endRecovery('second');
    expect(status.phase, ServerConnectionPhase.disconnected);
  });

  test('a working profile does not hide interrupted background chat', () {
    final status = ServerConnectionStatus('Claw');
    addTearDown(status.dispose);
    status.accessAvailable();
    status.liveChanged('work', true);
    status.liveChanged('travel', false);
    expect(status.phase, ServerConnectionPhase.limited);
    expect(status.description, 'Live updates interrupted');
    status.liveChanged('travel', true);
    expect(status.phase, ServerConnectionPhase.connected);
  });

  test(
    'a lost device network reports offline at once, even mid-recovery, until restored',
    () {
      final status = ServerConnectionStatus('Claw');
      addTearDown(status.dispose);
      status.accessAvailable();
      status.liveChanged('work', true);
      expect(status.phase, ServerConnectionPhase.connected);
      // An unrelated, in-flight server-side recovery would normally keep the
      // phase at "reconnecting" (see the independent-observations test
      // above); the device's own network loss must override that display.
      status.beginRecovery('work');
      expect(status.phase, ServerConnectionPhase.reconnecting);
      status.networkLost();
      expect(status.phase, ServerConnectionPhase.disconnected);
      // The in-flight recovery can finish while the radio is still down; the
      // network signal, not the recovery outcome, must stay authoritative.
      status.endRecovery('work');
      expect(status.phase, ServerConnectionPhase.disconnected);
      status.networkRestored();
      expect(status.phase, ServerConnectionPhase.connected);
    },
  );

  test('rejected operation proves access; sign-in and TLS need action', () {
    final status = ServerConnectionStatus('Claw');
    addTearDown(status.dispose);
    status.accessFailed(const DashboardHttpException(404, '/sessions/removed'));
    expect(status.access, ConnectionAvailability.available);
    status.accessFailed(const DashboardHttpException(401, '/auth'));
    expect(status.access, ConnectionAvailability.unavailable);
    expect(status.problem, contains('Sign-in'));
    status.accessFailed(const HandshakeException('certificate detail'));
    expect(status.phase, ServerConnectionPhase.disconnected);
    expect(status.problem, 'The server’s certificate could not be verified.');
    status.accessAvailable();
    expect(status.problem, isNull);
  });
}
