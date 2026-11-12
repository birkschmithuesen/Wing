import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'attachment_image_preflight.dart';

/// Streams native selections through a bounded image preflight before Flutter
/// or Hermes decodes them. Provider-reported file sizes are not trusted.
class BotAvatarIo {
  Future<Uint8List?> pick() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
    );
    if (file == null) return null;
    final bytes = BytesBuilder(copy: false);
    var size = 0;
    await for (final chunk in file.readAsByteStream()) {
      size += chunk.length;
      if (size > 2000000) {
        throw StateError('Choose a PNG, JPEG or WebP smaller than 2 MB.');
      }
      bytes.add(chunk);
    }
    final image = bytes.takeBytes();
    inspectAttachmentImage(image);
    return image;
  }
}
