// Adapted from image 4.10.1 lib/src/formats/webp/webp_alpha.dart.
// Locked source SHA-256 and allocation inventory:
// internal/lib/core/services/attachment_image_codec_audit.md.
// Allocation charges precede each input-driven allocation, including extensions.
// MIT copyright (c) 2013-2022 Brendan Duncan; full license in image_codec.LICENSE.
// ignore_for_file: invalid_use_of_internal_member
part of 'attachment_image_worker.dart';

class _BudgetedWebPAlpha {
  InputBuffer input;
  final _ImageAllocationBudget budget;
  int width = 0;
  int height = 0;
  int method = 0;
  int filter = 0;
  int preProcessing = 0;
  int rsrv = 1;
  bool isAlphaDecoded = false;

  _BudgetedWebPAlpha(this.input, this.width, this.height, this.budget) {
    final b = input.readByte();
    method = b & 0x03;
    filter = (b >> 2) & 0x03;
    preProcessing = (b >> 4) & 0x03;
    rsrv = (b >> 6) & 0x03;

    if (isValid) {
      if (!_decodeAlphaHeader()) {
        rsrv = 1;
      }
    }
  }

  bool get isValid {
    if (method != _alphaLosslessCompression ||
        filter >= WebPFilters.filterLast ||
        preProcessing > _alphaPreprocessedLevels ||
        rsrv != 0) {
      return false;
    }
    return true;
  }

  bool decode(int row, int numRows, Uint8List output) {
    if (!isValid) {
      return false;
    }

    final unfilterFunc = WebPFilters.unfilters[filter];

    if (!_decodeAlphaImageStream(row + numRows, output)) {
      return false;
    }

    if (unfilterFunc != null) {
      // Pinned filters construct row-local InputBuffer wrappers. Charge before
      // the filter loop, including narrow/tall streams with few pixel bytes.
      budget.charge(1024 + numRows * 384, 'alpha filter row wrappers');
      unfilterFunc(width, height, width, row, numRows, output);
    }

    if (preProcessing == _alphaPreprocessedLevels) {
      if (!_dequantizeLevels(output, width, height, row, numRows)) {
        return false;
      }
    }

    if (row + numRows >= height) {
      isAlphaDecoded = true;
    }

    return true;
  }

  bool _dequantizeLevels(
    Uint8List data,
    int width,
    int height,
    int row,
    int numRows,
  ) {
    if (width <= 0 ||
        height <= 0 ||
        row < 0 ||
        numRows < 0 ||
        row + numRows > height) {
      return false;
    }
    return true;
  }

  bool _decodeAlphaImageStream(int lastRow, Uint8List output) {
    _vp8l.opaque = output;
    // Decode (with special row processing).
    return _use8bDecode
        ? _vp8l.decodeAlphaData(_vp8l.webp.width, _vp8l.webp.height, lastRow)
        : _vp8l.decodeImageData(
            _vp8l.pixels!,
            _vp8l.webp.width,
            _vp8l.webp.height,
            lastRow,
            _vp8l.extractAlphaRows,
          );
  }

  bool _decodeAlphaHeader() {
    final webp = WebPInfo()
      ..width = width
      ..height = height;

    budget.charge(512, 'alpha decoder state');
    _vp8l = _BudgetedInternalVP8L(input, webp, budget)
      ..ioWidth = width
      ..ioHeight = height;

    _vp8l.decodeImageStream(webp.width, webp.height, true);

    // Special case: if alpha data uses only the color indexing transform and
    // doesn't use color cache (a frequent case), we will use DecodeAlphaData()
    // method that only needs allocation of 1 byte per pixel (alpha channel).
    if (_vp8l.transforms.length == 1 &&
        _vp8l.transforms[0].type == VP8LImageTransformType.colorIndexing &&
        _vp8l.is8bOptimizable()) {
      _use8bDecode = true;
      _vp8l.allocateInternalBuffers8b();
    } else {
      _use8bDecode = false;
      _vp8l.allocateInternalBuffers32b(width);
    }

    return true;
  }

  late _BudgetedInternalVP8L _vp8l;

  // Although alpha channel
  // requires only 1 byte per
  // pixel, sometimes VP8LDecoder may need to allocate
  // 4 bytes per pixel internally during decode.
  bool _use8bDecode = false;

  // Alpha related constants.
  static const _alphaLosslessCompression = 1;
  static const _alphaPreprocessedLevels = 1;
}
