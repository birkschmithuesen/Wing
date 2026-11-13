import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as image_lib;
// The pinned codec internals implement the privately owned allocation boundary.
// ignore_for_file: invalid_use_of_internal_member, implementation_imports
import 'package:image/src/formats/webp/vp8l_bit_reader.dart';
import 'package:image/src/formats/webp/vp8l_color_cache.dart';
import 'package:image/src/formats/webp/vp8l_transform.dart';
import 'package:image/src/formats/webp/webp_filters.dart';
import 'package:image/src/formats/webp/webp_huffman.dart';
import 'package:image/src/formats/webp/webp_info.dart';
import 'package:image/src/util/color_util.dart';
import 'package:image/src/util/image_exception.dart';
import 'package:image/src/util/input_buffer.dart';

import '../models/attachment_draft.dart';
import 'attachment_image_preflight.dart';

part 'attachment_image_vp8l.dart';
part 'attachment_image_alpha.dart';
part 'attachment_image_webp.dart';

/// Runtime transport seam: computation completion and resource exit are separate.
class AttachmentImageProcess {
  AttachmentImageProcess(this._kill, {required this.exited});
  final void Function() _kill;
  final Future<void> exited;
  var _killed = false;
  void kill() {
    if (_killed) return;
    _killed = true;
    _kill();
  }
}

typedef AttachmentImageProcessStarter =
    Future<AttachmentImageProcess> Function(
      SendPort result,
      Object input,
      int outputLimit,
    );

class SanitizedAttachmentImage {
  const SanitizedAttachmentImage(this.bytes, this.inspection);
  final Uint8List bytes;
  final AttachmentImageInspection inspection;
  bool get isJpeg => inspection.format == AttachmentImageFormat.jpeg;
}

/// A cancellation handle owns the computation, never a destination file.
class AttachmentImageJob {
  AttachmentImageJob._(
    this._input,
    this._outputLimit,
    this._reservedBytes,
    this._startProcess,
  );
  final AttachmentImageProcessStarter _startProcess;
  final Object _input;
  final int _outputLimit;
  final int _reservedBytes;
  final _result = Completer<SanitizedAttachmentImage>();
  final _started = Completer<void>();
  AttachmentImageProcess? _process;
  ReceivePort? _port;
  bool _cancelled = false;
  Future<SanitizedAttachmentImage> get result => _result.future;
  Future<void> get started => _started.future;
  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    if (_result.isCompleted) return;
    // Port closure can synchronously complete stream.first in a test zone.
    // Settle authority before kill/close can reenter the worker error path.
    _result.completeError(
      const AttachmentImageException('Image preparation was cancelled.'),
    );
    _process?.kill();
    _port?.close();
    if (!identical(AttachmentImageWorker._active, this)) {
      if (!_started.isCompleted) _started.complete();
      AttachmentImageWorker._finish(this);
    }
  }
}

/// One process-wide queue bounds simultaneous codec work and retained inputs.
/// Each job uses a fresh isolate, so kill cancels a synchronous decoder too.
final class AttachmentImageWorker {
  AttachmentImageWorker({AttachmentImageProcessStarter? startProcess})
    : _startProcess = startProcess ?? _startRuntime;
  final AttachmentImageProcessStarter _startProcess;
  static final shared = AttachmentImageWorker();
  static final _queue = Queue<AttachmentImageJob>();
  static AttachmentImageJob? _active;
  static var _reservedBytes = 0;

  AttachmentImageJob prepareBytes(
    Uint8List bytes, {
    required int maxOutputBytes,
  }) => _enqueue(bytes, bytes.length, maxOutputBytes);

  AttachmentImageJob prepareFile(String path, {required int maxOutputBytes}) =>
      _enqueue(path, maxAttachmentImageInputBytes, maxOutputBytes);

  AttachmentImageJob _enqueue(Object input, int reserved, int limit) {
    if (reserved <= 0 ||
        reserved > maxAttachmentImageInputBytes ||
        reserved > maxAttachmentImageInputBytes - _reservedBytes ||
        _queue.length + (_active == null ? 0 : 1) >= 10) {
      throw const AttachmentImageException(
        'Image preparation input budget is full.',
      );
    }
    if (limit <= 0 || limit > maxAttachmentImageOutputBytes) {
      throw const AttachmentImageException(
        'The image exceeds the remaining attachment budget.',
      );
    }
    // Transfer only after admission. No closure captures the service/controller.
    final job = AttachmentImageJob._(
      input is Uint8List ? TransferableTypedData.fromList([input]) : input,
      limit,
      reserved,
      _startProcess,
    );
    _reservedBytes += reserved;
    _queue.add(job);
    _pump();
    return job;
  }

  static void _finish(AttachmentImageJob job) {
    if (identical(_active, job)) {
      _active = null;
    } else if (!_queue.remove(job)) {
      return;
    }
    _reservedBytes -= job._reservedBytes;
    job._port?.close();
    _pump();
  }

  static void _pump() {
    if (_active != null || _queue.isEmpty) return;
    final job = _active = _queue.removeFirst();
    _run(job);
  }

  static Future<void> _run(AttachmentImageJob job) async {
    final port = job._port = ReceivePort();
    try {
      final process = await job._startProcess(
        port.sendPort,
        job._input,
        job._outputLimit,
      );
      job._process = process;
      // Relay exit to the result port after observing its separate resource ack.
      // A worker that exits without a result must fail, rather than strand work.
      unawaited(process.exited.then((_) => port.sendPort.send(['exited'])));
      if (job._cancelled) {
        process.kill();
        return;
      }
      if (!job._started.isCompleted) job._started.complete();
      final message = await port.first;
      if (job._cancelled) return;
      if (message is List && message.length == 3 && message[0] == 'ok') {
        final bytes = (message[1] as TransferableTypedData)
            .materialize()
            .asUint8List();
        job._result.complete(
          SanitizedAttachmentImage(
            bytes,
            message[2] as AttachmentImageInspection,
          ),
        );
      } else if (message is List &&
          message.length == 2 &&
          message[0] == 'invalid') {
        job._result.completeError(
          AttachmentImageException(message[1] as String),
        );
      } else {
        job._result.completeError(
          const AttachmentImageException(
            'Unable to sanitize this image safely.',
          ),
        );
      }
    } catch (_) {
      if (!job._result.isCompleted) {
        job._result.completeError(
          const AttachmentImageException('Unable to prepare this image.'),
        );
      }
    } finally {
      final process = job._process;
      if (process != null) {
        process.kill();
        // kill is a request, not a synchronous resource-release proof. If exit
        // stalls, retain occupancy rather than run a replacement concurrently.
        await process.exited;
      }
      if (!job._started.isCompleted) job._started.complete();
      _finish(job);
    }
  }

  static Future<AttachmentImageProcess> _startRuntime(
    SendPort result,
    Object input,
    int limit,
  ) async {
    final exitPort = ReceivePort();
    final exited = Completer<void>();
    exitPort.listen((_) {
      if (!exited.isCompleted) exited.complete();
      exitPort.close();
    });
    try {
      final isolate = await Isolate.spawn<List<Object>>(
        _transform,
        [result, input, limit],
        debugName: 'wing-attachment-image',
        onError: result,
        onExit: exitPort.sendPort,
      );
      return AttachmentImageProcess(
        () => isolate.kill(priority: Isolate.immediate),
        exited: exited.future,
      );
    } catch (_) {
      exitPort.close();
      rethrow;
    }
  }

  static Future<Uint8List> _readBounded(String path) async {
    final file = await File(path).open();
    final builder = BytesBuilder(copy: false);
    try {
      while (true) {
        // One extra byte detects growth without reading the enlarged file whole.
        final remaining = maxAttachmentImageInputBytes - builder.length;
        final chunk = await file.read(
          remaining < 65536 ? remaining + 1 : 65536,
        );
        if (chunk.isEmpty) break;
        if (chunk.length > remaining) {
          throw const AttachmentImageException(
            'The image exceeds the 64 MiB input limit.',
          );
        }
        builder.add(chunk);
      }
      return builder.takeBytes();
    } finally {
      await file.close();
    }
  }

  static Future<void> _transform(List<Object> args) async {
    final output = args[0] as SendPort;
    try {
      final input = args[1];
      final bytes = input is TransferableTypedData
          ? input.materialize().asUint8List()
          : await _readBounded(input as String);
      var inspection = inspectAttachmentImage(bytes);
      final codecSource = attachmentImageCodecSource(bytes, inspection);
      final decoded = switch (inspection.format) {
        AttachmentImageFormat.jpeg => image_lib.decodeJpg(codecSource),
        AttachmentImageFormat.png => image_lib.decodePng(codecSource),
        AttachmentImageFormat.webp => (() {
          final result = decodeBoundedAttachmentWebP(codecSource, inspection);
          inspection = AttachmentImageInspection(
            format: inspection.format,
            width: inspection.width,
            height: inspection.height,
            frames: inspection.frames,
            chargedBytes: result.chargedBytes,
            orientation: inspection.orientation,
          );
          return result.image;
        })(),
      };
      if (decoded == null) {
        throw const AttachmentImageException(
          'The selected image could not be decoded safely.',
        );
      }
      decoded.exif.imageIfd.orientation = inspection.orientation;
      var sanitized = image_lib.bakeOrientation(decoded);
      for (final frame in sanitized.frames) {
        frame.exif.clear();
        frame.iccProfile = null;
        frame.textData = null;
      }
      // Palette APNG encoding otherwise invokes an additional neural quantizer.
      if (sanitized.hasPalette) sanitized = sanitized.convert(numChannels: 4);
      final encoded = inspection.format == AttachmentImageFormat.jpeg
          ? image_lib.encodeJpg(sanitized, quality: 85)
          : image_lib.encodePng(sanitized, level: 6);
      if (encoded.length > (args[2] as int)) {
        throw const AttachmentImageException(
          'The sanitized image exceeds the attachment upload budget.',
        );
      }
      Isolate.exit(output, [
        'ok',
        TransferableTypedData.fromList([encoded]),
        inspection,
      ]);
    } on AttachmentImageException catch (error) {
      Isolate.exit(output, ['invalid', error.message]);
    } catch (_) {
      Isolate.exit(output, [
        'invalid',
        'Unable to sanitize this image. Choose a valid JPEG, PNG, or WebP image.',
      ]);
    }
  }
}

/// Pure isolate entry point for a room icon; callers never import image codecs.
Uint8List encodeRoomThumbnail((Uint8List, int) input) {
  final (bytes, maxBytes) = input;
  if (bytes.length > maxRoomPictureInputBytes) {
    throw StateError('Room picture exceeds 8 MB');
  }
  final inspection = inspectAttachmentImage(bytes);
  final source = attachmentImageCodecSource(bytes, inspection);
  final decoded = switch (inspection.format) {
    AttachmentImageFormat.jpeg => image_lib.decodeJpg(source),
    AttachmentImageFormat.png => image_lib.decodePng(source),
    AttachmentImageFormat.webp => decodeBoundedAttachmentWebP(
      source,
      inspection,
    ).image,
  };
  if (decoded == null) throw const FormatException('Invalid room picture');
  final frame = decoded.frames.first;
  frame.exif.imageIfd.orientation = inspection.orientation;
  final square = image_lib.copyResizeCropSquare(
    image_lib.bakeOrientation(frame),
    size: 256,
  );
  square.exif.clear();
  square.iccProfile = null;
  square.textData = null;
  final png = image_lib.encodePng(square);
  if (png.length <= maxBytes) return png;
  // JPEG cannot represent alpha. Reduce transparent artwork's resolution
  // instead, retaining fully transparent pixels and soft edges in PNG.
  if (square.any((pixel) => pixel.aNormalized < 1)) {
    for (final size in [192, 128, 96, 64]) {
      final smaller = image_lib.copyResize(square, width: size, height: size);
      final candidate = image_lib.encodePng(smaller);
      if (candidate.length <= maxBytes) return candidate;
    }
    throw StateError('Room picture could not fit the upload limit');
  }
  for (final quality in [85, 70, 50]) {
    final jpeg = image_lib.encodeJpg(
      square,
      quality: quality,
      chroma: image_lib.JpegChroma.yuv420,
    );
    if (jpeg.length <= maxBytes) return jpeg;
  }
  throw StateError('Room picture could not fit the upload limit');
}
