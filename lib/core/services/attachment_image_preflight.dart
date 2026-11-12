import 'dart:io';
import 'dart:typed_data';

import '../models/attachment_draft.dart';

/// Client processing ceilings, separate from the stock 25 MiB image upload cap.
const maxAttachmentImageInputBytes = 64 * 1024 * 1024;
// Generated room originals use stock Hermes' 8 MB transfer budget before the
// worker crops them to the much smaller saved metadata icon.
const maxRoomPictureInputBytes = 8000000;
const maxAttachmentImageOutputBytes = 25 * 1024 * 1024;
const maxAttachmentImagePixels = 16 * 1024 * 1024;
const maxAttachmentImageSide = 16384;
const maxAttachmentImageFrames = 16;
const maxAttachmentImageDecodedBytes = 64 * 1024 * 1024;
// PNG chunks retained for palette/color decoding still need an allocation cap.
// Metadata removed before decoding is bounded only by the input file limit.
const maxAttachmentImageRetainedPngBytes = 256 * 1024;
const maxAttachmentImageRecords = 4096;
const maxAttachmentImageChargedBytes = 256 * 1024 * 1024;

class AttachmentImageException implements Exception {
  const AttachmentImageException(this.message);
  final String message;
}

/// Charges known codec allocation drivers; this is not a measured VM heap bound.
/// Header inspection bounds the container; the bounded worker separately
/// charges VP8L entropy tables and lossless/alpha decoding allocations.
class AttachmentImageInspection {
  AttachmentImageInspection({
    required this.format,
    required this.width,
    required this.height,
    required this.frames,
    required this.chargedBytes,
    this.orientation = 1,
    List<(int, int)> discardedMetadata = const [],
  }) : _discardedMetadata = List.unmodifiable(discardedMetadata);
  final AttachmentImageFormat format;
  final int width;
  final int height;
  final int frames;
  final int chargedBytes;
  final int orientation;
  final List<(int, int)> _discardedMetadata;
}

Never _invalid([
  String message = 'The image is invalid or exceeds processing limits.',
]) => throw AttachmentImageException(message);

int _u16(Uint8List b, int p) => (b[p] << 8) | b[p + 1];
int _u32(Uint8List b, int p) =>
    (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];
int _le24(Uint8List b, int p) => b[p] | (b[p + 1] << 8) | (b[p + 2] << 16);
int _le32(Uint8List b, int p) => _le24(b, p) | (b[p + 3] << 24);
String _tag(Uint8List b, int p) => String.fromCharCodes(b.sublist(p, p + 4));
void _dimensions(int w, int h) {
  if (w <= 0 ||
      h <= 0 ||
      w > maxAttachmentImageSide ||
      h > maxAttachmentImageSide ||
      w > maxAttachmentImagePixels ~/ h) {
    _invalid('The image dimensions exceed the client processing limit.');
  }
}

AttachmentImageInspection _inspection(
  AttachmentImageFormat format,
  int w,
  int h,
  int frames,
  int sampleBytes,
  int inputBytes,
  int decodeCharge, {
  int orientation = 1,
  List<(int, int)> discardedMetadata = const [],
}) {
  _dimensions(w, h);
  final pixels = w * h;
  if (frames < 1 ||
      frames > maxAttachmentImageFrames ||
      pixels * sampleBytes > maxAttachmentImageDecodedBytes ~/ frames) {
    _invalid('The image frames exceed the client processing limit.');
  }
  final decoded = pixels * sampleBytes * frames;
  // Keep the original and transformed images reserved through encoding.
  final transform = inputBytes * 2 + decoded * 3;
  final scanlines = decoded + h * frames;
  final encode = format == AttachmentImageFormat.jpeg
      ? inputBytes * 2 + decoded + scanlines * 3 + 1024 * 1024
      : _pngEncodeCharge(w, h, frames, sampleBytes, inputBytes);
  final charged = [
    decodeCharge + inputBytes,
    transform,
    encode,
  ].reduce((a, b) => a > b ? a : b);
  if (charged > maxAttachmentImageChargedBytes) {
    _invalid('The image requires too much processing memory.');
  }
  return AttachmentImageInspection(
    format: format,
    width: w,
    height: h,
    frames: frames,
    chargedBytes: charged,
    orientation: orientation,
    discardedMetadata: discardedMetadata,
  );
}

int _pngEncodeCharge(
  int w,
  int h,
  int frames,
  int sampleBytes,
  int inputBytes,
) {
  // Reserve either orientation, including the extra filter byte on every row.
  final side = w > h ? w : h;
  final pixels = w * h * sampleBytes;
  final filtered = pixels + side;
  // zlib compressBound for the pinned native encoder's default window/memory.
  final compressed =
      filtered + (filtered >> 12) + (filtered >> 14) + (filtered >> 25) + 13;
  // Each frame has its own zlib stream, 64 KiB IDAT/fdAT chunks and headers.
  final encoded =
      frames * (compressed + ((compressed + 65535) ~/ 65536) * 16 + 4096);
  // OutputBuffer grows by max(old * 3, required + 8192). Old/new overlap and
  // transferring the finished view each fit 4 * encoded + fixed headroom.
  // Two full RGBA canvases also cover palette originals plus RGBA conversion.
  return inputBytes * 2 +
      pixels * frames * 2 +
      encoded * 4 +
      (side * sampleBytes + 1) * 3 +
      1024 * 1024;
}

AttachmentImageInspection inspectAttachmentImage(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > maxAttachmentImageInputBytes) _invalid();
  if (bytes.length >= 3 &&
      bytes[0] == 255 &&
      bytes[1] == 216 &&
      bytes[2] == 255) {
    return _jpeg(bytes);
  }
  if (bytes.length >= 8 &&
      bytes[0] == 137 &&
      _tag(bytes, 1) == 'PNG\r' &&
      bytes[5] == 10 &&
      bytes[6] == 26 &&
      bytes[7] == 10) {
    return _png(bytes);
  }
  if (bytes.length >= 12 &&
      _tag(bytes, 0) == 'RIFF' &&
      _tag(bytes, 8) == 'WEBP') {
    return _webp(bytes);
  }
  _invalid('Unsupported image format. Choose a JPEG, PNG, or WebP image.');
}

AttachmentImageInspection _jpeg(Uint8List b) {
  var p = 2, records = 0;
  int? width, height;
  var coefficientBytes = 0, coefficientBlocks = 0, tableBytes = 0;
  var ended = false;
  var orientation = 1;
  final discardedMetadata = <(int, int)>[];
  while (p < b.length) {
    if (b[p++] != 255) _invalid();
    while (p < b.length && b[p] == 255) {
      p++;
    }
    if (p >= b.length || ++records > maxAttachmentImageRecords) _invalid();
    final markerStart = p - 1;
    final marker = b[p++];
    if (marker == 217) {
      ended = true;
      break;
    }
    if (marker == 0 || marker == 216 || (marker >= 208 && marker <= 215)) {
      _invalid();
    }
    if (p + 2 > b.length) _invalid();
    final length = _u16(b, p);
    if (length < 2 || length > b.length - p) _invalid();
    final end = p + length;
    if ((marker >= 224 && marker <= 239) || marker == 254) {
      // JFIF/Adobe carry decode color-space hints; every other APP/comment is
      // stripped before the codec, so EXIF cannot allocate arbitrary IFD chains.
      if (marker != 224 && marker != 238) {
        discardedMetadata.add((markerStart, end));
      }
      if (marker == 225 &&
          length >= 8 &&
          _tag(b, p + 2) == 'Exif' &&
          b[p + 6] == 0 &&
          b[p + 7] == 0) {
        orientation = _tiffOrientation(b, p + 8, end);
      }
    }
    if (marker == 196) {
      // DHT: reject table drivers before decoder tree allocation.
      var q = p + 2;
      while (q < end) {
        if (end - q < 17) _invalid();
        final selector = b[q++];
        if ((selector >> 4) > 1 || (selector & 15) > 3) _invalid();
        var count = 0, available = 1;
        for (var i = 0; i < 16; i++) {
          final n = b[q++];
          count += n;
          available = available * 2 - n;
          if (available < 0) _invalid('Invalid JPEG Huffman code lengths.');
        }
        if (count == 0 || count > 256 || count > end - q) _invalid();
        // Tree nodes plus the 512-entry Uint16 lookahead and table wrappers.
        tableBytes += count * 16 * 64 + 2304;
        if (tableBytes > maxAttachmentImageChargedBytes) _invalid();
        q += count;
      }
    } else if (marker == 219) {
      // DQT precision and table IDs drive fixed arrays.
      var q = p + 2;
      while (q < end) {
        final selector = b[q++];
        final precision = selector >> 4;
        if (precision > 1 || (selector & 15) > 3) _invalid();
        final n = 64 * (precision + 1);
        if (n > end - q) _invalid();
        tableBytes += 64 * 4 + 128;
        if (tableBytes > maxAttachmentImageChargedBytes) _invalid();
        q += n;
      }
    }
    if (marker == 192 || marker == 193 || marker == 194) {
      if (width != null || length < 8 || b[p + 2] != 8) _invalid();
      height = _u16(b, p + 3);
      width = _u16(b, p + 5);
      _dimensions(width, height);
      final components = b[p + 7];
      if (!(components == 1 || components == 3 || components == 4) ||
          length != 8 + components * 3) {
        _invalid();
      }
      var maxH = 0, maxV = 0;
      final sampling = <(int, int)>[];
      final ids = <int>{};
      for (var i = 0; i < components; i++) {
        final q = p + 8 + i * 3;
        final h = b[q + 1] >> 4, v = b[q + 1] & 15;
        if (!ids.add(b[q]) ||
            h < 1 ||
            h > 4 ||
            v < 1 ||
            v > 4 ||
            b[q + 2] > 3) {
          _invalid();
        }
        sampling.add((h, v));
        if (h > maxH) maxH = h;
        if (v > maxV) maxV = v;
      }
      final mx = (width + 8 * maxH - 1) ~/ (8 * maxH);
      final my = (height + 8 * maxV - 1) ~/ (8 * maxV);
      for (final s in sampling) {
        coefficientBlocks += mx * my * s.$1 * s.$2;
      }
      coefficientBytes = coefficientBlocks * 128;
      // Flat Int16 MCU coefficients are allocated only after this preflight.
      if (coefficientBytes > maxAttachmentImageChargedBytes) _invalid();
    } else if (marker >= 192 &&
        marker <= 207 &&
        marker != 196 &&
        marker != 200 &&
        marker != 204) {
      _invalid('This JPEG coding mode is unsupported.');
    }
    p = end;
    if (marker == 218) {
      if (width == null) _invalid();
      // Entropy data contains stuffed FF00 and standalone restart markers.
      while (p < b.length) {
        if (b[p] != 255) {
          p++;
          continue;
        }
        final start = p++;
        while (p < b.length && b[p] == 255) {
          p++;
        }
        if (p == b.length) _invalid();
        final code = b[p];
        if (code == 0 || (code >= 208 && code <= 215)) {
          p++;
          continue;
        }
        p = start;
        break;
      }
    }
  }
  if (!ended || width == null || height == null) _invalid();
  if (p != b.length) {
    // Nothing after the first EOI contributes pixels. Discard it without
    // interpreting vendor capture directories or other appended metadata.
    discardedMetadata.add((p, b.length));
  }
  final decode =
      b.length +
      // A late APP14 or second scan can retain the streaming decoder while
      // restarting a full decode: two coefficient sets, zero-band scratch,
      // two component-line sets, both tables and both output canvases.
      coefficientBytes * 4 +
      tableBytes * 2 +
      coefficientBlocks * 48 +
      width * height * 8 +
      1024 * 1024;
  return _inspection(
    AttachmentImageFormat.jpeg,
    width,
    height,
    1,
    4,
    b.length,
    decode,
    orientation: orientation,
    discardedMetadata: discardedMetadata,
  );
}

class _InflatedCounter implements Sink<List<int>> {
  _InflatedCounter(this.limit);
  final int limit;
  var count = 0;
  @override
  void add(List<int> bytes) {
    if (bytes.length > limit - count) {
      _invalid('PNG inflation exceeds its declared scanlines.');
    }
    count += bytes.length;
  }

  @override
  void close() {}
}

int _scanlines(int w, int h, int channels, int bits, int interlace) {
  if (interlace == 0) return ((w * channels * bits + 7) ~/ 8 + 1) * h;
  const xs = [0, 4, 0, 2, 0, 1, 0], ys = [0, 0, 4, 0, 2, 0, 1];
  const xd = [8, 8, 4, 4, 2, 2, 1], yd = [8, 8, 8, 4, 4, 2, 2];
  var total = 0;
  for (var i = 0; i < 7; i++) {
    final pw = w <= xs[i] ? 0 : (w - xs[i] + xd[i] - 1) ~/ xd[i];
    final ph = h <= ys[i] ? 0 : (h - ys[i] + yd[i] - 1) ~/ yd[i];
    if (pw > 0 && ph > 0) total += ((pw * channels * bits + 7) ~/ 8 + 1) * ph;
  }
  return total;
}

void _checkInflation(Uint8List b, List<(int, int)> ranges, int expected) {
  final output = _InflatedCounter(expected);
  final decoder = ZLibCodec().decoder.startChunkedConversion(output);
  try {
    for (final range in ranges) {
      for (var p = range.$1; p < range.$2; p += 1024) {
        final end = p + 1024 < range.$2 ? p + 1024 : range.$2;
        decoder.add(Uint8List.sublistView(b, p, end));
      }
    }
    decoder.close();
    if (output.count != expected) {
      _invalid('PNG scanline data does not match its dimensions.');
    }
  } on AttachmentImageException {
    rethrow;
  } catch (_) {
    _invalid('PNG compressed data is invalid.');
  }
}

AttachmentImageInspection _png(Uint8List b) {
  var p = 8,
      records = 0,
      retainedBytes = 0,
      w = 0,
      h = 0,
      bits = 0,
      channels = 0;
  var interlace = 0, declaredFrames = 1, frameW = 0, frameH = 0;
  var seenHeader = false, ended = false, seenData = false, frameControls = 0;
  var hasAnimation = false, idatClosed = false;
  var compressed = 0, totalInflated = 0;
  var ranges = <(int, int)>[];
  final discardedMetadata = <(int, int)>[];
  void finishFrame() {
    if (ranges.isEmpty) return;
    final expected = _scanlines(frameW, frameH, channels, bits, interlace);
    _checkInflation(b, ranges, expected);
    totalInflated += expected;
    ranges = [];
  }

  while (p + 12 <= b.length) {
    final size = _u32(b, p), tag = _tag(b, p + 4), data = p + 8;
    if (size > b.length - p - 12 || ++records > maxAttachmentImageRecords) {
      _invalid();
    }
    final end = data + size;
    if (!seenHeader && tag != 'IHDR') _invalid();
    switch (tag) {
      case 'IHDR':
        if (seenHeader || size != 13) _invalid();
        seenHeader = true;
        w = _u32(b, data);
        h = _u32(b, data + 4);
        _dimensions(w, h);
        frameW = w;
        frameH = h;
        bits = b[data + 8];
        final color = b[data + 9];
        channels = switch (color) {
          0 => 1,
          2 => 3,
          3 => 1,
          4 => 2,
          6 => 4,
          _ => 0,
        };
        final validBits = color == 0
            ? [1, 2, 4, 8, 16]
            : color == 3
            ? [1, 2, 4, 8]
            : [8, 16];
        if (channels == 0 ||
            !validBits.contains(bits) ||
            b[data + 10] != 0 ||
            b[data + 11] != 0 ||
            b[data + 12] > 1) {
          _invalid();
        }
        interlace = b[data + 12];
      case 'acTL':
        if (size != 8 || seenData || hasAnimation) _invalid();
        hasAnimation = true;
        declaredFrames = _u32(b, data);
        _inspection(
          AttachmentImageFormat.png,
          w,
          h,
          declaredFrames,
          bits == 16 ? 8 : 4,
          b.length,
          0,
        );
      case 'fcTL':
        if (!hasAnimation) _invalid();
        if (seenData) idatClosed = true;
        finishFrame();
        if (size != 26 || ++frameControls > declaredFrames) _invalid();
        frameW = _u32(b, data + 4);
        frameH = _u32(b, data + 8);
        _dimensions(frameW, frameH);
        final x = _u32(b, data + 12), y = _u32(b, data + 16);
        if (frameW > w ||
            frameH > h ||
            x > w - frameW ||
            y > h - frameH ||
            b[data + 24] > 2 ||
            b[data + 25] > 1) {
          _invalid();
        }
      case 'IDAT':
        if (idatClosed) _invalid();
        seenData = true;
        compressed += size;
        ranges.add((data, end));
      case 'fdAT':
        if (size < 4 || !seenData || frameControls < 1) _invalid();
        compressed += size - 4;
        ranges.add((data + 4, end));
      case 'IEND':
        if (size != 0 || !seenData) _invalid();
        finishFrame();
        ended = true;
      default:
        if (const {'tEXt', 'zTXt', 'iTXt', 'iCCP', 'eXIf'}.contains(tag)) {
          discardedMetadata.add((p, end + 4));
        } else {
          retainedBytes += size;
          if (retainedBytes > maxAttachmentImageRetainedPngBytes) _invalid();
        }
    }
    p = end + 4;
    if (ended) break;
  }
  if (!ended ||
      p != b.length ||
      (declaredFrames > 1 && frameControls != declaredFrames)) {
    _invalid();
  }
  final decoded = w * h * (bits == 16 ? 8 : 4) * declaredFrames;
  return _inspection(
    AttachmentImageFormat.png,
    w,
    h,
    declaredFrames,
    bits == 16 ? 8 : 4,
    b.length,
    b.length +
        compressed * 2 +
        // Lazy inflation can fill its window from a whole compressed chunk.
        // A doubled window overlaps the old allocation: at most 3 * output.
        totalInflated * 3 +
        decoded +
        w * h * (bits == 16 ? 8 : 4) * 2 +
        w * (bits == 16 ? 8 : 4) * 3 +
        declaredFrames * 65536 +
        1024 * 1024,
    discardedMetadata: discardedMetadata,
  );
}

AttachmentImageInspection _webp(Uint8List b) {
  if (_le32(b, 4) != b.length - 8) _invalid();
  var p = 12, records = 0, w = 0, h = 0, frames = 0;
  var orientation = 1;
  final discardedMetadata = <(int, int)>[];
  void bitstream(String tag, int data, int end, int expectedW, int expectedH) {
    int fw, fh;
    if (tag == 'VP8L') {
      if (end - data < 5 || b[data] != 47) _invalid();
      final packed = _le32(b, data + 1);
      if (packed >> 29 != 0) _invalid();
      fw = (packed & 16383) + 1;
      fh = ((packed >> 14) & 16383) + 1;
    } else {
      if (end - data < 10 ||
          b[data] & 1 != 0 ||
          b[data + 3] != 157 ||
          b[data + 4] != 1 ||
          b[data + 5] != 42) {
        _invalid();
      }
      fw = (b[data + 6] | (b[data + 7] << 8)) & 16383;
      fh = (b[data + 8] | (b[data + 9] << 8)) & 16383;
    }
    _dimensions(fw, fh);
    if (expectedW != 0 && (fw != expectedW || fh != expectedH)) _invalid();
    if (w == 0) {
      w = fw;
      h = fh;
    }
  }

  while (p + 8 <= b.length) {
    final tag = _tag(b, p), size = _le32(b, p + 4), data = p + 8;
    if (size > b.length - data || ++records > maxAttachmentImageRecords) {
      _invalid();
    }
    final end = data + size;
    switch (tag) {
      case 'VP8X':
        if (size != 10 || w != 0) _invalid();
        w = _le24(b, data + 4) + 1;
        h = _le24(b, data + 7) + 1;
        _dimensions(w, h);
      case 'VP8 ':
      case 'VP8L':
        if (++frames != 1) _invalid();
        bitstream(tag, data, end, w, h);
      case 'ANMF':
        if (size < 16 || w == 0 || ++frames > maxAttachmentImageFrames) {
          _invalid();
        }
        final fw = _le24(b, data + 6) + 1, fh = _le24(b, data + 9) + 1;
        final x = _le24(b, data) * 2, y = _le24(b, data + 3) * 2;
        if (fw > w || fh > h || x > w - fw || y > h - fh) _invalid();
        var q = data + 16, found = false;
        while (q + 8 <= end) {
          final nested = _tag(b, q), n = _le32(b, q + 4), d = q + 8;
          if (n > end - d || ++records > maxAttachmentImageRecords) _invalid();
          if (nested == 'VP8 ' || nested == 'VP8L') {
            if (found) _invalid();
            found = true;
            bitstream(nested, d, d + n, fw, fh);
          } else if (nested == 'ALPH') {
            // Header inspection cannot audit the compressed-alpha entropy tables.
            if (n == 0) _invalid();
          } else {
            _invalid();
          }
          q = d + n + (n & 1);
        }
        if (!found || q != end) _invalid();
      case 'ALPH':
        if (size == 0) _invalid();
      case 'EXIF':
      case 'ICCP':
      case 'XMP ':
        discardedMetadata.add((p, end + (size & 1)));
        if (tag == 'EXIF') orientation = _tiffOrientation(b, data, end);
      case 'ANIM':
        if (size != 6) _invalid();
      default:
        _invalid();
    }
    p = end + (size & 1);
  }
  if (p != b.length || frames == 0) _invalid();
  // VP8 macroblock coefficient, YUV/filter and RGBA buffers are charged with a
  // padded 16x16 canvas. VP8L's entropy-table allocation is explicitly pending.
  final padded = ((w + 15) ~/ 16) * ((h + 15) ~/ 16) * 256;
  return _inspection(
    AttachmentImageFormat.webp,
    w,
    h,
    frames,
    4,
    b.length,
    b.length + padded * 24 + w * h * 4 * frames,
    orientation: orientation,
    discardedMetadata: discardedMetadata,
  );
}

int _tiffOrientation(Uint8List bytes, int start, int end) {
  // Optional metadata never reaches the codec. Use a transform only when its
  // direct inline value can be read safely; damaged metadata leaves pixels as-is.
  if (end - start < 8) return 1;
  final little = bytes[start] == 73 && bytes[start + 1] == 73;
  if (!little && !(bytes[start] == 77 && bytes[start + 1] == 77)) return 1;
  final data = ByteData.sublistView(bytes, start, end);
  final endian = little ? Endian.little : Endian.big;
  if (data.getUint16(2, endian) != 42) return 1;
  final offset = data.getUint32(4, endian);
  if (offset == 0) return 1;
  if (offset > data.lengthInBytes - 2) return 1;
  final count = data.getUint16(offset, endian);
  if (count > (data.lengthInBytes - offset - 2) ~/ 12) return 1;
  for (var i = 0; i < count; i++) {
    final p = offset + 2 + i * 12;
    if (data.getUint16(p, endian) != 0x112) continue;
    final type = data.getUint16(p + 2, endian);
    if ((type != 3 && type != 4) || data.getUint32(p + 4, endian) != 1) {
      return 1;
    }
    final orientation = type == 3
        ? data.getUint16(p + 8, endian)
        : data.getUint32(p + 8, endian);
    // Samsung screenshots store an inline LONG zero (unspecified orientation).
    // The worker applies only actual orientation transforms, then strips EXIF.
    if (orientation > 8) return 1;
    return orientation;
  }
  return 1;
}

/// Remove privacy metadata before codec parsing, keeping only direct bounded
/// orientation. Pixel/color-space chunks and image entropy bytes are unchanged.
Uint8List attachmentImageCodecSource(
  Uint8List bytes,
  AttachmentImageInspection inspection,
) {
  if (inspection._discardedMetadata.isEmpty) return bytes;
  final builder = BytesBuilder(copy: false);
  var p = 0;
  for (final range in inspection._discardedMetadata) {
    builder.add(Uint8List.sublistView(bytes, p, range.$1));
    p = range.$2;
  }
  builder.add(Uint8List.sublistView(bytes, p));
  final stripped = builder.takeBytes();
  if (inspection.format == AttachmentImageFormat.webp) {
    ByteData.sublistView(
      stripped,
    ).setUint32(4, stripped.length - 8, Endian.little);
    // Metadata-presence bits in VP8X must match the stripped container.
    if (stripped.length >= 30 && _tag(stripped, 12) == 'VP8X') {
      stripped[20] &= ~(0x20 | 0x08 | 0x04);
    }
  }
  return stripped;
}
