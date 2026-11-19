import 'package:wing/core/services/connection_manager.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/server_connection_status.dart';

void main() {
  test('waiting recovery permits retry unless another owner is active', () {
    final status = ServerConnectionStatus('Claw');
    addTearDown(status.dispose);
    status.waitForRecovery('chat');
    expect(status.phase, ServerConnectionPhase.reconnecting);
    expect(status.recoveryAttemptInProgress, isFalse);
    status.beginRecovery('other');
    expect(status.recoveryAttemptInProgress, isTrue);
    status.endRecovery('other');
    expect(status.recoveryAttemptInProgress, isFalse);
    status.beginRecovery('chat');
    expect(status.recoveryAttemptInProgress, isTrue);
    status.failRecovery('chat', 'Sign-in required');
    expect(status.recoveryAttemptInProgress, isFalse);
    expect(status.phase, ServerConnectionPhase.disconnected);
  });

  test('HTTP success cannot hide a chat endpoint mismatch', () {
    final status = ServerConnectionStatus('Claw');
    addTearDown(status.dispose);
    status.accessAvailable();
    status.observeChatEndpoint(false);
    status.liveChanged('default', true);
    status.accessAvailable();
    expect(status.phase, ServerConnectionPhase.disconnected);
    expect(status.description, 'Chat address needs changing');
    expect(status.problem, contains('Webapp address'));
    status.observeChatEndpoint(true);
    expect(status.phase, ServerConnectionPhase.connected);
    expect(status.problem, isNull);
  });

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

  test(
    'a focused owner is not kept reconnecting by a different, background owner',
    () {
      final status = ServerConnectionStatus('Claw');
      addTearDown(status.dispose);
      status.accessAvailable();
      status.liveChanged('birk', true);
      status.focusOwner('birk');
      expect(status.phase, ServerConnectionPhase.connected);
      // A profile the user never switched away from (e.g. the chat
      // overview's filter chips) is still mid-resume; it must not reopen
      // the header or block a retry meant for the focused profile.
      status.beginRecovery('cothinker');
      expect(status.phase, ServerConnectionPhase.connected);
      expect(status.recoveryAttemptInProgress, isFalse);
      status.failRecovery('cothinker', 'Chat could not be reopened');
      expect(status.phase, ServerConnectionPhase.connected);
      expect(status.problem, isNull);
      // The focused profile's own recovery still gates everything.
      status.beginRecovery('birk');
      expect(status.phase, ServerConnectionPhase.reconnecting);
      expect(status.recoveryAttemptInProgress, isTrue);
      status.endRecovery('birk');
      expect(status.phase, ServerConnectionPhase.connected);
      // Connection-wide pseudo-owners gate regardless of which profile has
      // focus: opening a notification is not yet the focused profile's own
      // concern.
      status.beginRecovery('notification');
      expect(status.phase, ServerConnectionPhase.reconnecting);
      status.endRecovery('notification');
      expect(status.phase, ServerConnectionPhase.connected);
    },
  );

  test(
    'a background owner going live-unavailable does not turn the header '
    'orange for the focused owner (cold reconnect storm, t_1d748269)',
    () {
      final status = ServerConnectionStatus('Claw');
      addTearDown(status.dispose);
      status.accessAvailable();
      status.liveChanged('birk', true);
      status.liveChanged('cothinker', true);
      status.focusOwner('birk');
      expect(status.phase, ServerConnectionPhase.connected);
      // A background profile's socket actually closing (not just mid-resume,
      // see the other focus test) must not poison the aggregate `live` the
      // header's phase used to read directly.
      status.liveChanged('cothinker', false);
      expect(status.phase, ServerConnectionPhase.connected);
      expect(status.description, 'Connected');
      // The focused owner's own live chat still gates the header.
      status.liveChanged('birk', false);
      expect(status.phase, ServerConnectionPhase.limited);
      expect(status.description, 'Live updates interrupted');
    },
  );

  test('switching focus to a different owner re-evaluates phase', () {
    final status = ServerConnectionStatus('Claw');
    addTearDown(status.dispose);
    status.accessAvailable();
    status.liveChanged('birk', true);
    status.liveChanged('cothinker', true);
    status.beginRecovery('cothinker');
    status.focusOwner('birk');
    expect(status.phase, ServerConnectionPhase.connected);
    status.focusOwner('cothinker');
    expect(status.phase, ServerConnectionPhase.reconnecting);
    status.focusOwner(null);
    expect(status.phase, ServerConnectionPhase.reconnecting);
  });
}
