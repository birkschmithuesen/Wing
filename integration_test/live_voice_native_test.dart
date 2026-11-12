import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wing/core/services/live_voice_transport.dart';

class _Lifecycle extends WidgetsBindingObserver {
  final paused = Completer<void>(), resumed = Completer<void>();
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && !paused.isCompleted) {
      paused.complete();
    }
    if (state == AppLifecycleState.resumed &&
        paused.isCompleted &&
        !resumed.isCompleted) {
      resumed.complete();
    }
  }
}

/// Local WebRTC peer only: proves native audio/lifetime, never provider access.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'duplex microphone survives Home and lock independently of monitoring',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: Text('Wing duplex audio acceptance')),
          ),
        ),
      );
      final lifecycle = _Lifecycle();
      WidgetsBinding.instance.addObserver(lifecycle);
      final transport = WebRtcLiveVoiceTransport(),
          service = AndroidLiveVoiceBackground();
      final remote = await createPeerConnection({});
      final ready = Completer<void>(), echoed = Completer<void>();
      final muted = Completer<void>(), ended = Completer<void>();
      addTearDown(() async {
        WidgetsBinding.instance.removeObserver(lifecycle);
        await transport.close();
        await service.stop();
        await remote.close();
        await remote.dispose();
      });
      remote.onDataChannel = (channel) {
        channel.onMessage = (message) {
          if (!message.isBinary && message.text.contains('probe')) {
            channel.send(
              RTCDataChannelMessage(jsonEncode({'type': 'probe.received'})),
            );
          }
        };
      };
      final offer = await transport.open(
        onEvent: (event) {
          if (event['type'] == 'probe.received' && !echoed.isCompleted) {
            echoed.complete();
          }
        },
        onReady: () {
          if (!ready.isCompleted) ready.complete();
        },
        onDisconnected: () {},
      );
      expect(offer, contains('m=audio'));
      await service.start('Duplex acceptance', '', (action) {
        if (action == 'mute') {
          unawaited(() async {
            await transport.mute(true);
            await service.muted(true);
            if (!muted.isCompleted) muted.complete();
          }());
        }
        if (action == 'end' && !ended.isCompleted) ended.complete();
      });
      final ice = Completer<void>();
      remote.onIceGatheringState = (state) {
        if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
            !ice.isCompleted) {
          ice.complete();
        }
      };
      await remote.setRemoteDescription(RTCSessionDescription(offer, 'offer'));
      await remote.setLocalDescription(await remote.createAnswer());
      if (remote.iceGatheringState ==
              RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !ice.isCompleted) {
        ice.complete();
      }
      await ice.future.timeout(const Duration(seconds: 12));
      await transport.answer((await remote.getLocalDescription())!.sdp!);
      await ready.future.timeout(const Duration(seconds: 15));
      transport.send({'type': 'probe'});
      await echoed.future.timeout(const Duration(seconds: 5));
      Future<int> packets() async {
        final stats = await remote.getStats();
        return stats
            .where((s) => s.type == 'inbound-rtp')
            .fold<int>(
              0,
              (sum, row) =>
                  sum + ((row.values['packetsReceived'] as num?)?.toInt() ?? 0),
            );
      }

      final before = await packets();
      debugPrint('VOICE_DUPLEX_READY');
      await lifecycle.paused.future.timeout(const Duration(seconds: 30));
      await Future<void>.delayed(const Duration(seconds: 2));
      final after = await packets();
      expect(
        after,
        greaterThan(before),
        reason: 'Audio packets must continue while the phone is locked',
      );
      debugPrint('VOICE_DUPLEX_BACKGROUND');
      await lifecycle.resumed.future.timeout(const Duration(seconds: 30));
      debugPrint('VOICE_DUPLEX_RESUMED');
      await muted.future.timeout(const Duration(seconds: 30));
      expect(await Helper.isMicrophoneMuted(), isTrue);
      debugPrint('VOICE_DUPLEX_MUTED');
      await ended.future.timeout(const Duration(seconds: 30));
      await transport.close();
      await service.stop();
      debugPrint('VOICE_DUPLEX_ENDED');
    },
  );
}
