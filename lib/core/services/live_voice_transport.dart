import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'live_voice_session.dart';
import 'android_voice.dart';

class WebRtcLiveVoiceTransport implements LiveVoiceTransport {
  RTCPeerConnection? _peer;
  RTCDataChannel? _channel;
  MediaStream? _microphone;
  bool _closed = false;
  final _ice = Completer<void>();

  @override
  Future<String> open({
    required void Function(Map<String, dynamic>) onEvent,
    required void Function() onReady,
    required void Function() onDisconnected,
  }) async {
    await const MethodChannel(
      'com.tarkilhk.wing/live_voice',
    ).invokeMethod<void>('prepare');
    final granted = await AndroidVoice.channel.invokeMethod<bool>(
      'requestLivePermissions',
    );
    if (granted != true) throw StateError('Microphone permission is required');
    if (_closed) throw StateError('Call ended');
    await Helper.setAndroidAudioConfiguration(
      AndroidAudioConfiguration.communication,
    );
    if (_closed) throw StateError('Call ended');
    final microphone = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': false,
    });
    _microphone = microphone;
    if (_closed) {
      await _releaseMicrophone();
      throw StateError('Call ended');
    }
    await Helper.setMicrophoneMuted(false);
    if (_closed) throw StateError('Call ended');
    final peer = await createPeerConnection({});
    _peer = peer;
    if (_closed) {
      await peer.close();
      await peer.dispose();
      throw StateError('Call ended');
    }
    peer.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !_ice.isCompleted) {
        _ice.complete();
      }
    };
    peer.onConnectionState = (state) {
      if (_closed) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        onDisconnected();
      }
    };
    for (final track in microphone.getAudioTracks()) {
      await peer.addTrack(track, microphone);
    }
    if (_closed) throw StateError('Call ended');
    final channel = await peer.createDataChannel(
      'oai-events',
      RTCDataChannelInit(),
    );
    _channel = channel;
    if (_closed) {
      await channel.close();
      throw StateError('Call ended');
    }
    channel.onDataChannelState = (state) {
      if (!_closed && state == RTCDataChannelState.RTCDataChannelOpen) {
        onReady();
      }
    };
    channel.onMessage = (message) {
      if (_closed || message.isBinary || message.text.length > 256 * 1024) {
        return;
      }
      try {
        final event = jsonDecode(message.text);
        if (event is Map<String, dynamic>) onEvent(event);
      } on FormatException {
        /* Ignore malformed provider events, never execute them. */
      }
    };
    final offer = await peer.createOffer({'offerToReceiveAudio': true});
    await peer.setLocalDescription(offer);
    if (peer.iceGatheringState ==
            RTCIceGatheringState.RTCIceGatheringStateComplete &&
        !_ice.isCompleted) {
      _ice.complete();
    }
    await _ice.future.timeout(const Duration(seconds: 12));
    if (_closed) throw StateError('Call ended');
    await Helper.setSpeakerphoneOnButPreferBluetooth();
    return (await peer.getLocalDescription())!.sdp!;
  }

  @override
  Future<void> answer(String sdp) async {
    if (!_closed) {
      await _peer?.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    }
  }

  @override
  Future<void> send(Map<String, dynamic> event) async {
    final channel = _channel;
    if (_closed || channel?.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw StateError('Voice data channel is not open');
    }
    await channel!.send(RTCDataChannelMessage(jsonEncode(event)));
  }

  @override
  Future<void> mute(bool muted) async {
    if (!_closed) await Helper.setMicrophoneMuted(muted);
  }

  @override
  Future<void> speaker(bool enabled) => Helper.setSpeakerphoneOn(enabled);

  Future<void> _releaseMicrophone() async {
    final stream = _microphone;
    _microphone = null;
    if (stream == null) return;
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await stream.dispose();
  }

  @override
  Future<void> close() async {
    if (_closed) {
      await _releaseMicrophone();
      return;
    }
    try {
      await send({'type': 'session.close'});
    } catch (_) {
      /* Release audio even when the transport has already failed. */
    }
    _closed = true;
    if (!_ice.isCompleted) _ice.complete();
    await _releaseMicrophone();
    final channel = _channel, peer = _peer;
    _channel = null;
    _peer = null;
    try {
      await channel?.close();
    } finally {
      try {
        await peer?.close();
      } finally {
        await peer?.dispose();
      }
    }
  }
}

class AndroidLiveVoiceBackground implements LiveVoiceBackground {
  static const _channel = MethodChannel('com.tarkilhk.wing/live_voice');
  @override
  Future<void> start(
    String title,
    String payload,
    void Function(String) action,
  ) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'action' && call.arguments is String) {
        action(call.arguments as String);
      }
    });
    await _channel.invokeMethod<void>('start', {
      'title': title,
      'payload': payload,
    });
  }

  @override
  Future<void> muted(bool value) => _channel.invokeMethod('muted', value);
  @override
  Future<void> stop() async {
    await _channel.invokeMethod<void>('stop');
    _channel.setMethodCallHandler(null);
  }
}
