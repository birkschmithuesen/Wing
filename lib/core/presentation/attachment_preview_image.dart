import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../services/attachment_draft_service.dart';

/// A renderer for an owner-issued image read capability. Its cache key contains
/// no encoded payload, and unchanged upload/error state does not reload it.
final class AttachmentPreviewImage
    extends ImageProvider<AttachmentPreviewSource> {
  const AttachmentPreviewImage(this.source);

  final AttachmentPreviewSource source;

  @override
  Future<AttachmentPreviewSource> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(source);

  @override
  ImageStreamCompleter loadImage(
    AttachmentPreviewSource key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(codec: _load(key, decode), scale: 1);

  Future<ui.ImmutableBuffer> _readBuffer(AttachmentPreviewSource key) async =>
      ui.ImmutableBuffer.fromUint8List(await key.readBytes());

  Future<ui.Codec> _load(
    AttachmentPreviewSource key,
    ImageDecoderCallback decode,
  ) async {
    final buffer = await _readBuffer(key);
    // The standard Flutter decoder takes ownership and disposes this buffer.
    // Target dimensions bound the resulting thumbnail, not engine peak memory.
    return decode(
      buffer,
      getTargetSize: (width, height) {
        if (width <= 256 && height <= 256) {
          return ui.TargetImageSize(width: width, height: height);
        }
        if (width >= height) {
          final scaled = height * 256 ~/ width;
          return ui.TargetImageSize(
            width: 256,
            height: scaled < 1 ? 1 : scaled,
          );
        }
        final scaled = width * 256 ~/ height;
        return ui.TargetImageSize(width: scaled < 1 ? 1 : scaled, height: 256);
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AttachmentPreviewImage && other.source == source;

  @override
  int get hashCode => source.hashCode;
}
