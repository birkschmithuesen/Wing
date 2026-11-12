import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Only a server-confirmed lease matching our private viewer identity grants input.
class BotDisplayLease {
  const BotDisplayLease(this.holder, this.viewerHash, this.epoch);
  factory BotDisplayLease.parse(Object? value) {
    if (value is! Map ||
        !{'agent', 'human'}.contains(value['holder']) ||
        value['epoch'] is! int ||
        (value['epoch'] as int) < 0 ||
        (value['holder'] == 'human' &&
            (value['viewer_hash'] is! String ||
                !RegExp(
                  r'^[0-9a-f]{12}$',
                ).hasMatch(value['viewer_hash'] as String))) ||
        (value['holder'] == 'agent' && value['viewer_hash'] != null)) {
      throw const FormatException('Invalid screen control state');
    }
    return BotDisplayLease(
      value['holder'] as String,
      value['viewer_hash'] as String?,
      value['epoch'] as int,
    );
  }
  final String holder;
  final String? viewerHash;
  final int epoch;
  bool ownedBy(String? viewer) =>
      viewer != null &&
      holder == 'human' &&
      viewerHash ==
          sha256.convert(utf8.encode(viewer)).toString().substring(0, 12);
}

class BotDisplayStatus {
  BotDisplayStatus.parse(Map<String, dynamic> value)
    : supported = _bool(value, 'supported'),
      installed = _bool(value, 'installed'),
      running = _bool(value, 'running'),
      blocker = value['blocker'] as String?,
      installCommand = value['install_command'] as String?,
      lease = BotDisplayLease.parse(value['lease']);
  final bool supported, installed, running;
  final String? blocker, installCommand;
  final BotDisplayLease lease;
  static bool _bool(Map<String, dynamic> value, String key) {
    if (value[key] is! bool) throw FormatException('Invalid screen $key');
    return value[key] as bool;
  }
}

/// A complete RGBA frame; a stream publication owns its pixel buffer.
class BotDisplayFrame {
  BotDisplayFrame(this.width, this.height, Uint8List pixels)
    : pixels = pixels.asUnmodifiableView();
  final int width, height;
  final Uint8List pixels;
}
