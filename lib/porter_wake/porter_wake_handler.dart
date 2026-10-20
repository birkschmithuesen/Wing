import 'package:flutter/foundation.dart';

import 'porter_wake_api.dart';
import 'porter_wake_bridge.dart';
import 'porter_wake_ledger.dart';
import 'porter_wake_payload.dart';
import 'porter_wake_presentation.dart';

typedef PorterApiFor = Future<PorterWakeApi?> Function(String connectionId);
typedef PorterOpenProfile = Future<void> Function(String connectionId, String profile);

/// Push → fetch → show, and notification taps → feedback (contract §6).
class PorterWakeHandler {
  PorterWakeHandler({
    required this.bridge,
    required this.ledger,
    required this.apiFor,
    this.openProfile,
  });

  final PorterWakeBridge bridge;
  final PorterNoticeLedger ledger;
  final PorterApiFor apiFor;
  final PorterOpenProfile? openProfile;

  Future<void> onPush(String connectionId, List<int> bytes) async {
    final payload = PorterWakePayload.parse(bytes);
    if (payload == null) {
      debugPrint('porter_wake: ignored a push that is not porter_wake v1');
      return;
    }
    if (!await ledger.claim(payload.noticeId)) return;
    try {
      await bridge.show(await _specFor(connectionId, payload.noticeId));
    } on Object {
      await ledger.release(payload.noticeId);
      rethrow;
    }
  }

  Future<PorterNotificationSpec> _specFor(String connectionId, String noticeId) async {
    try {
      final api = await apiFor(connectionId);
      if (api != null) {
        return PorterNotificationSpec.fromNotice(connectionId, await api.notice(noticeId));
      }
    } on Object catch (error) {
      debugPrint('porter_wake: notice fetch failed (${error.runtimeType})');
    }
    return PorterNotificationSpec.neutral(connectionId, noticeId);
  }

  Future<bool> onInteraction(PorterInteractionEvent event) async {
    final api = await apiFor(event.connectionId);
    if (event.action == 'open') {
      var profile = event.openProfile;
      if (api != null) {
        try {
          if (event.neutral) profile = (await api.notice(event.noticeId)).openProfile;
          await api.feedback(event.noticeId, const {'action': 'open'});
        } on Object catch (error) {
          debugPrint('porter_wake: open feedback failed (${error.runtimeType})');
        }
      }
      await bridge.cancel();
      await openProfile?.call(event.connectionId, profile);
      return true;
    }
    final value = event.value;
    if (api == null || value == null || !const {'rate', 'snooze'}.contains(event.action)) {
      return false;
    }
    try {
      // applied:false is the server's idempotent repeat and counts as success.
      await api.feedback(event.noticeId, {'action': event.action, 'value': value});
    } on Object catch (error) {
      debugPrint('porter_wake: feedback failed (${error.runtimeType})');
      return false;
    }
    await bridge.cancel();
    return true;
  }
}
