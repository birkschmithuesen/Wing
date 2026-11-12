import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/server_connection_status.dart';

void main() {
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
}
