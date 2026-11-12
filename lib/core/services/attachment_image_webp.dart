// Codec policy and animation assembly for the worker's bounded WebP decoder.
// The lossless entropy and alpha implementations live in private worker parts.
// ignore_for_file: invalid_use_of_internal_member
part of 'attachment_image_worker.dart';

final class _ImageAllocationBudget {
  _ImageAllocationBudget(int initial) : charged = initial {
    if (initial < 0 || initial > maxAttachmentImageChargedBytes) {
      throw const AttachmentImageException('Invalid image allocation charge.');
    }
  }
  int charged;
  void charge(int bytes, String driver) {
    if (bytes < 0 || bytes > maxAttachmentImageChargedBytes - charged) {
      throw AttachmentImageException('Image allocation limit: $driver.');
    }
    charged += bytes;
  }

  Uint8List uint8(int count, String driver) {
    charge(count + 64, driver);
    return Uint8List(count);
  }

  Uint16List uint16(int count, String driver) {
    charge(count * 2 + 64, driver);
    return Uint16List(count);
  }

  Uint32List uint32(int count, String driver) {
    charge(count * 4 + 64, driver);
    return Uint32List(count);
  }

  Int32List int32(int count, String driver) {
    charge(count * 4 + 64, driver);
    return Int32List(count);
  }

  image_lib.Image image(int width, int height) {
    charge(width * height * 4 + 4096, 'lossless output pixels');
    return image_lib.Image(width: width, height: height, numChannels: 4);
  }

  VP8LTransform transform(int rows) {
    charge(256 + rows * 128, 'transform objects and per-row multipliers');
    return VP8LTransform();
  }

  VP8LColorCache colorCache(int bits) {
    charge((1 << bits) * 4 + 64, 'color cache');
    return VP8LColorCache(bits);
  }

  List<HTreeGroup> groups(int count) {
    charge(count * 4096 + 64, 'Huffman groups and packed tables');
    return List<HTreeGroup>.generate(
      count,
      (_) => HTreeGroup(),
      growable: false,
    );
  }

  HuffmanTables tables(int count, String driver) {
    chargeHuffman(count, driver);
    return HuffmanTables(count);
  }

  HuffmanCodeList huffman(int count, String driver) {
    chargeHuffman(count, driver);
    return HuffmanCodeList(count);
  }

  // Each object has two tagged integer fields; 64 charges object/header,
  // reference slot, alignment, and the owning list. This is conservative driver
  // accounting, not a promise about allocator pages or measured peak RSS.
  void chargeHuffman(int entries, String driver) =>
      charge(entries * 64 + 256, driver);
}

class BoundedAttachmentWebPResult {
  const BoundedAttachmentWebPResult(this.image, this.chargedBytes);
  final image_lib.Image image;
  final int chargedBytes;
}

/// Receives bytes already checked by [inspectAttachmentImage]. No source IO,
/// upload, UI or cancellation ownership crosses this codec boundary.
BoundedAttachmentWebPResult decodeBoundedAttachmentWebP(
  Uint8List bytes,
  AttachmentImageInspection inspection,
) {
  if (inspection.format != AttachmentImageFormat.webp) {
    throw const AttachmentImageException('Expected a validated WebP image.');
  }
  final budget = _ImageAllocationBudget(inspection.chargedBytes);
  // Preflight bounds the global top-level plus nested record count at4096.
  // Include objects, tags, typed-data views and transient list growth.
  budget.charge(2 * 1024 * 1024, 'WebP chunk bookkeeping');
  final chunks = _webpChunks(bytes, 12, bytes.length);
  final animated = chunks.where((c) => c.tag == 'ANMF').toList(growable: false);
  if (animated.isEmpty) {
    final decoded = _decodeWebpPixels(
      chunks,
      inspection.width,
      inspection.height,
      budget,
    );
    return BoundedAttachmentWebPResult(decoded, budget.charged);
  }
  final anim = chunks.firstWhere((c) => c.tag == 'ANIM').data;
  final loop = anim[4] | (anim[5] << 8);
  final background = image_lib.ColorRgba8(anim[2], anim[1], anim[0], anim[3]);
  image_lib.Image? first, last;
  _WebpRectangle? previous;
  for (final chunk in animated) {
    final d = chunk.data;
    final rectangle = _WebpRectangle(
      _webp24(d, 0) * 2,
      _webp24(d, 3) * 2,
      _webp24(d, 6) + 1,
      _webp24(d, 9) + 1,
      _webp24(d, 12),
      d[15] & 1 != 0,
      d[15] & 2 == 0,
    );
    final pixels = _decodeWebpPixels(
      _webpChunks(d, 16, d.length),
      rectangle.width,
      rectangle.height,
      budget,
    );
    // Retained canvases were reserved by the original frame/transform charge.
    if (last == null) {
      first = last = image_lib.Image(
        width: inspection.width,
        height: inspection.height,
        numChannels: pixels.numChannels,
        format: pixels.format,
        frameDuration: rectangle.duration,
        loopCount: loop,
        backgroundColor: background,
      );
    } else {
      last = image_lib.Image.from(last);
      if (previous != null && previous.clear) {
        image_lib.fillRect(
          last,
          x1: previous.x,
          y1: previous.y,
          x2: previous.x + previous.width - 1,
          y2: previous.y + previous.height - 1,
          color: image_lib.ColorRgba8(0, 0, 0, 0),
          alphaBlend: false,
        );
      }
    }
    last.frameDuration = rectangle.duration;
    image_lib.compositeImage(
      last,
      pixels,
      dstX: rectangle.x,
      dstY: rectangle.y,
      blend: rectangle.blend
          ? image_lib.BlendMode.alpha
          : image_lib.BlendMode.direct,
    );
    if (!identical(first, last)) first!.addFrame(last);
    previous = rectangle;
  }
  return BoundedAttachmentWebPResult(first!, budget.charged);
}

class _WebpRectangle {
  const _WebpRectangle(
    this.x,
    this.y,
    this.width,
    this.height,
    this.duration,
    this.clear,
    this.blend,
  );
  final int x, y, width, height, duration;
  final bool clear, blend;
}

class _WebpChunk {
  const _WebpChunk(this.tag, this.data);
  final String tag;
  final Uint8List data;
}

int _webp24(Uint8List b, int p) => b[p] | (b[p + 1] << 8) | (b[p + 2] << 16);
int _webp32(Uint8List b, int p) => _webp24(b, p) | (b[p + 3] << 24);
List<_WebpChunk> _webpChunks(Uint8List b, int p, int end) {
  final chunks = <_WebpChunk>[];
  while (p < end) {
    if (p + 8 > end || chunks.length >= maxAttachmentImageRecords) {
      throw const AttachmentImageException('Invalid WebP chunk list.');
    }
    final n = _webp32(b, p + 4);
    if (n > end - p - 8) {
      throw const AttachmentImageException('Invalid WebP chunk size.');
    }
    chunks.add(
      _WebpChunk(
        String.fromCharCodes(Uint8List.sublistView(b, p, p + 4)),
        Uint8List.sublistView(b, p + 8, p + 8 + n),
      ),
    );
    p += 8 + n + (n & 1);
  }
  if (p != end) throw const AttachmentImageException('Invalid WebP padding.');
  return chunks;
}

image_lib.Image _decodeWebpPixels(
  List<_WebpChunk> chunks,
  int width,
  int height,
  _ImageAllocationBudget budget,
) {
  final lossless = chunks.where((c) => c.tag == 'VP8L').firstOrNull;
  if (lossless != null) {
    final info = WebPInfo();
    budget.charge(512, 'lossless decoder state');
    final decoded = _BudgetedVP8L(
      InputBuffer(lossless.data),
      info,
      budget,
    ).decode();
    if (decoded == null || decoded.width != width || decoded.height != height) {
      throw const AttachmentImageException('Invalid lossless WebP image.');
    }
    return decoded;
  }
  final lossy = chunks.firstWhere((c) => c.tag == 'VP8 ');
  final alpha = chunks.where((c) => c.tag == 'ALPH').firstOrNull;
  Uint8List? rawAlpha;
  if (alpha != null && alpha.data[0] & 3 == 1) {
    // Decompress/filter alpha once with the bounded decoder. The package lossy
    // decoder sees only raw ALPH and cannot instantiate its unbounded VP8L.
    rawAlpha = budget.uint8(width * height + 1, 'raw alpha output');
    final alphaDecoder = _BudgetedWebPAlpha(
      InputBuffer(alpha.data),
      width,
      height,
      budget,
    );
    if (!alphaDecoder.decode(0, height, Uint8List.sublistView(rawAlpha, 1))) {
      throw const AttachmentImageException('Invalid compressed WebP alpha.');
    }
  }
  final selected = <_WebpChunk>[
    if (alpha != null) _WebpChunk('ALPH', rawAlpha ?? alpha.data),
    lossy,
  ];
  final total =
      12 +
      (alpha == null ? 0 : 18) +
      selected.fold<int>(
        0,
        (n, c) => n + 8 + c.data.length + (c.data.length & 1),
      );
  final container = budget.uint8(total, 'bounded lossy container');
  final words = ByteData.sublistView(container);
  void tag(int p, String tag) => container.setRange(p, p + 4, tag.codeUnits);
  tag(0, 'RIFF');
  words.setUint32(4, total - 8, Endian.little);
  tag(8, 'WEBP');
  var p = 12;
  if (alpha != null) {
    tag(p, 'VP8X');
    words.setUint32(p + 4, 10, Endian.little);
    container[p + 8] = 16;
    for (var i = 0; i < 3; i++) {
      container[p + 12 + i] = ((width - 1) >> (8 * i)) & 255;
      container[p + 15 + i] = ((height - 1) >> (8 * i)) & 255;
    }
    p += 18;
  }
  for (final chunk in selected) {
    tag(p, chunk.tag);
    words.setUint32(p + 4, chunk.data.length, Endian.little);
    container.setRange(p + 8, p + 8 + chunk.data.length, chunk.data);
    p += 8 + chunk.data.length + (chunk.data.length & 1);
  }
  final decoded = image_lib.decodeWebP(container);
  if (decoded == null || decoded.width != width || decoded.height != height) {
    throw const AttachmentImageException('Invalid lossy WebP image.');
  }
  return decoded;
}
