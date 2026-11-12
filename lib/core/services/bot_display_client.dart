import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../models/bot_display.dart';
import 'authenticated_web_socket.dart';

/// RFB 3.8 over the stock authenticated display bridge. Requests only raw pixels,
/// CopyRect, DesktopSize and UTF-8 clipboard; Xvnc paints its cursor into the requested framebuffer.
/// No password, clipboard read, secondary origin or legacy handshake is admitted.
class BotDisplayClient {
  // Named injectable transport seam.
  // ignore: prefer_initializing_formals
  BotDisplayClient({
    required Stream<dynamic> incoming,
    required void Function(Uint8List) send,
    required void Function() disconnect,
  }) : _bytes = _DisplayBytes(incoming),
       // ignore: prefer_initializing_formals
       _send = send,
       // ignore: prefer_initializing_formals
       _disconnect = disconnect;

  static Future<BotDisplayClient> connect(
    String baseUrl,
    String ticket,
    Map<String, String> headers,
  ) async {
    final base = Uri.parse(
      baseUrl.contains('://') ? baseUrl : 'https://$baseUrl',
    );
    if (!{'http', 'https'}.contains(base.scheme) ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment) {
      throw ArgumentError('Invalid screen gateway');
    }
    final path = base.path.replaceFirst(RegExp(r'/+$'), '');
    final uri = base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '$path/api/display/ws',
      queryParameters: {'display_ticket': ticket},
    );
    final channel = connectAuthenticatedWebSocket(
      uri,
      headers: headers,
      connectTimeout: const Duration(seconds: 15),
    );
    try {
      await channel.ready;
      return BotDisplayClient(
        incoming: channel.stream,
        send: channel.sink.add,
        disconnect: () {
          unawaited(channel.sink.close());
        },
      );
    } catch (_) {
      unawaited(channel.sink.close());
      rethrow;
    }
  }

  final _DisplayBytes _bytes;
  final void Function(Uint8List) _send;
  final void Function() _disconnect;
  final _frames = StreamController<BotDisplayFrame>();
  Stream<BotDisplayFrame> get frames => _frames.stream;
  bool _closed = false, _ready = false, _started = false;
  int _width = 0, _height = 0;
  Uint8List _pixels = Uint8List(0);
  Timer? _request;
  bool _clipboardReady = false;
  bool get clipboardReady => _clipboardReady && _ready && !_closed;

  Completer<void>? _clipboardTransfer;
  Uint8List? _clipboardPayload;
  bool Function()? _canProvideClipboard;

  /// Announces phone text, invokes paste, then answers the application's request.
  /// Never turn pasted newlines into executable Enter keys.
  Future<void> pasteClipboard(
    String text, {
    required bool Function() canProvide,
  }) async {
    if (!clipboardReady) {
      throw StateError('Clipboard is not ready. Reconnect and try again.');
    }
    if (_clipboardTransfer != null) {
      throw StateError('A paste is already in progress.');
    }
    if (!canProvide()) {
      throw StateError('Control changed. Take control before pasting.');
    }
    if (text.length > 256 * 1024) {
      throw StateError('Clipboard text is too large.');
    }
    final bytes = utf8.encode(
      '${text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').replaceAll('\n', '\r\n')}\x00',
    );
    if (bytes.length > 256 * 1024 - 16 || text.contains('\x00')) {
      throw StateError(
        'Clipboard text is too large or contains unsupported characters.',
      );
    }
    final data = ByteData(4)..setUint32(0, bytes.length);
    final compressed = zlib.encode([...data.buffer.asUint8List(), ...bytes]);
    if (compressed.length + 4 > 256 * 1024) {
      throw StateError('Clipboard text is too large.');
    }
    final header = ByteData(12)
      ..setUint8(0, 6)
      ..setInt32(4, -(compressed.length + 4))
      ..setUint32(8, 0x10000001);
    final transfer = Completer<void>();
    _clipboardTransfer = transfer;
    _clipboardPayload = Uint8List.fromList([
      ...header.buffer.asUint8List(),
      ...compressed,
    ]);
    _canProvideClipboard = canProvide;
    try {
      // Passive-viewer capabilities are dropped by Hermes's input gate. Repeat
      // them under the confirmed lease before offering this clipboard.
      _clipboardCapabilities();
      final notify = ByteData(12)
        ..setUint8(0, 6)
        ..setInt32(4, -4)
        ..setUint32(8, 0x08000001);
      _write(notify.buffer.asUint8List());
      key(0xffe3, true);
      key(0x76, true);
      key(0x76, false);
      key(0xffe3, false);
      await transfer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError(
          'Paste was not accepted. Select a text field on the computer and try again.',
        ),
      );
    } finally {
      _clipboardTransfer = null;
      _clipboardPayload = null;
      _canProvideClipboard = null;
    }
  }

  void _clipboardCapabilities() {
    final reply = ByteData(16)
      ..setUint8(0, 6)
      ..setInt32(4, -8)
      // Accept requests and notifications, never request remote clipboard data.
      ..setUint32(8, 0x0b000001)
      ..setUint32(12, 0);
    _write(reply.buffer.asUint8List());
  }

  Future<void> _clipboard() async {
    final header = await _bytes.read(7);
    final length = ByteData.sublistView(header).getInt32(3);
    final size = length.abs();
    if (size > 1024 * 1024) {
      throw const FormatException('Screen clipboard too large');
    }
    final payload = await _bytes.read(size);
    // Never request, decompress or publish clipboard contents from the desktop.
    if (length >= 0 || size < 4) return;
    final data = ByteData.sublistView(payload);
    final flags = data.getUint32(0);
    if (flags == 0x02000001 && size == 4) {
      final transfer = _clipboardTransfer;
      if (transfer == null || transfer.isCompleted) return;
      if (_canProvideClipboard?.call() != true) {
        transfer.completeError(
          StateError('Control changed. Take control before pasting.'),
        );
        return;
      }
      _write(_clipboardPayload!);
      transfer.complete();
      return;
    }
    if ((flags & 0x01000000) == 0) return;
    var formats = 0;
    for (var bit = 0; bit < 16; bit++) {
      if ((flags & (1 << bit)) != 0) formats++;
    }
    if (size != 4 + formats * 4) {
      throw const FormatException('Invalid clipboard capabilities');
    }
    _clipboardReady = (flags & 0x18000001) == 0x18000001;
    _clipboardCapabilities();
  }

  void start() {
    if (_started || _closed) return;
    _started = true;
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      await _handshake().timeout(const Duration(seconds: 20));
      while (!_closed) {
        final type = (await _bytes.read(1))[0];
        switch (type) {
          case 0:
            await _update();
          case 2:
            break; // Bell has no payload.
          case 3:
            await _clipboard();
          default:
            throw const FormatException('Unexpected screen message');
        }
      }
    } catch (error, stack) {
      if (!_closed) _frames.addError(error, stack);
    } finally {
      close();
    }
  }

  Future<void> _handshake() async {
    if (ascii.decode(await _bytes.read(12)) != 'RFB 003.008\n') {
      throw const FormatException('Screen requires RFB 3.8');
    }
    _write(ascii.encode('RFB 003.008\n'));
    final count = (await _bytes.read(1))[0];
    if (count == 0 || !(await _bytes.read(count)).contains(1)) {
      throw const FormatException(
        'Screen bridge did not offer ticket authentication',
      );
    }
    _write([1]);
    if (ByteData.sublistView(await _bytes.read(4)).getUint32(0) != 0) {
      throw const FormatException('Screen authentication failed');
    }
    _write([1]); // Shared viewer; opening does not evict another watcher.
    final init = ByteData.sublistView(await _bytes.read(24));
    _resize(init.getUint16(0), init.getUint16(2));
    final nameLength = init.getUint32(20);
    if (nameLength > 65536) {
      throw const FormatException('Screen name too large');
    }
    await _bytes.read(nameLength);
    // 32-bit little-endian true-colour RGBX -> red, green, blue, unused bytes.
    _write([
      0,
      0,
      0,
      0,
      32,
      24,
      0,
      1,
      0,
      255,
      0,
      255,
      0,
      255,
      0,
      8,
      16,
      0,
      0,
      0,
    ]);
    final encodings = ByteData(20)
      ..setUint8(0, 2)
      ..setUint16(2, 4)
      ..setInt32(4, 0)
      ..setInt32(8, 1)
      ..setInt32(12, -223)
      ..setUint32(16, 0xc0a1e5ce); // RFB ExtendedClipboard (TigerVNC).
    _write(encodings.buffer.asUint8List());
    _ready = true;
    _requestFrame(false);
  }

  void _resize(int width, int height) {
    if (width < 1 ||
        height < 1 ||
        width > 8192 ||
        height > 8192 ||
        width * height > 8 * 1024 * 1024) {
      throw const FormatException('Screen dimensions exceed the viewer budget');
    }
    _width = width;
    _height = height;
    _pixels = Uint8List(width * height * 4);
  }

  void _bounds(int x, int y, int w, int h) {
    if (x + w > _width || y + h > _height) {
      throw const FormatException('Screen rectangle outside framebuffer');
    }
  }

  Future<void> _update() async {
    final header = ByteData.sublistView(await _bytes.read(3));
    final rectangles = header.getUint16(1);
    var resized = false;
    for (var i = 0; i < rectangles; i++) {
      final r = ByteData.sublistView(await _bytes.read(12));
      final x = r.getUint16(0),
          y = r.getUint16(2),
          w = r.getUint16(4),
          h = r.getUint16(6),
          encoding = r.getInt32(8);
      if (encoding == -223) {
        _resize(w, h);
        resized = true;
        continue;
      }
      _bounds(x, y, w, h);
      switch (encoding) {
        case 0:
          final raw = await _bytes.read(w * h * 4);
          for (var row = 0; row < h; row++) {
            final offset = ((y + row) * _width + x) * 4;
            _pixels.setRange(offset, offset + w * 4, raw, row * w * 4);
            for (var column = 0; column < w; column++) {
              _pixels[offset + column * 4 + 3] = 255;
            }
          }
        case 1:
          final from = ByteData.sublistView(await _bytes.read(4));
          final sx = from.getUint16(0), sy = from.getUint16(2);
          _bounds(sx, sy, w, h);
          final copy = Uint8List(w * h * 4);
          for (var row = 0; row < h; row++) {
            final offset = ((sy + row) * _width + sx) * 4;
            copy.setRange(row * w * 4, (row + 1) * w * 4, _pixels, offset);
          }
          for (var row = 0; row < h; row++) {
            final offset = ((y + row) * _width + x) * 4;
            _pixels.setRange(offset, offset + w * 4, copy, row * w * 4);
          }
        default:
          throw const FormatException('Unrequested screen encoding');
      }
    }
    if (!_closed) {
      _frames.add(
        BotDisplayFrame(_width, _height, Uint8List.fromList(_pixels)),
      );
      // Backpressure: one outstanding update; no hidden polling or frame backlog.
      _request = Timer(
        const Duration(milliseconds: 100),
        () => _requestFrame(!resized),
      );
    }
  }

  void _requestFrame(bool incremental) {
    final data = ByteData(10)
      ..setUint8(0, 3)
      ..setUint8(1, incremental ? 1 : 0)
      ..setUint16(6, _width)
      ..setUint16(8, _height);
    _write(data.buffer.asUint8List());
  }

  void pointer(int x, int y, int buttons) {
    if (!_ready || _closed) return;
    final data = ByteData(6)
      ..setUint8(0, 5)
      ..setUint8(1, buttons)
      ..setUint16(2, x.clamp(0, _width - 1))
      ..setUint16(4, y.clamp(0, _height - 1));
    _write(data.buffer.asUint8List());
  }

  void key(int keysym, bool down) {
    if (!_ready || _closed) return;
    final data = ByteData(8)
      ..setUint8(0, 4)
      ..setUint8(1, down ? 1 : 0)
      ..setUint32(4, keysym);
    _write(data.buffer.asUint8List());
  }

  void _write(List<int> value) {
    if (!_closed) _send(Uint8List.fromList(value));
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _ready = false;
    _request?.cancel();
    final transfer = _clipboardTransfer;
    if (transfer != null && !transfer.isCompleted) {
      transfer.completeError(
        StateError('Screen disconnected before paste completed.'),
      );
    }
    _clipboardPayload = null;
    _canProvideClipboard = null;
    _disconnect();
    unawaited(_bytes.close());
    unawaited(_frames.close());
  }
}

/// Parses arbitrary WebSocket fragmentation without retaining consumed chunks.
class _DisplayBytes {
  _DisplayBytes(Stream<dynamic> incoming) : _input = StreamIterator(incoming);
  final StreamIterator<dynamic> _input;
  Uint8List _chunk = Uint8List(0);
  int _offset = 0;
  Future<Uint8List> read(int length) async {
    final result = Uint8List(length);
    var copied = 0;
    while (copied < length) {
      if (_offset == _chunk.length) {
        if (!await _input.moveNext()) {
          throw StateError('Screen connection closed');
        }
        final value = _input.current;
        if (value is! List<int> || value.length > 64 * 1024 * 1024) {
          throw const FormatException('Invalid screen stream');
        }
        _chunk = Uint8List.fromList(value);
        _offset = 0;
      }
      final count = (length - copied).clamp(0, _chunk.length - _offset);
      result.setRange(copied, copied + count, _chunk, _offset);
      copied += count;
      _offset += count;
    }
    return result;
  }

  Future<void> close() => _input.cancel();
}
