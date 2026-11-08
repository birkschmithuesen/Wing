import 'package:wing/core/services/group_observations.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:wing/core/services/bot_display_client.dart';
import 'package:wing/core/services/bots_repository.dart';
import 'bots_fixture.dart';

/// A stock RFB peer: all bytes pass through the production stream parser.
class DisplayPeer {
  DisplayPeer({this.fragment = false, this.width = 4, this.height = 3});
  final bool fragment;
  final int width, height;
  final input = StreamController<List<int>>();
  final sent = <Uint8List>[];
  bool closed = false;
  int phase = 0, requests = 0;
  bool requestClipboardOnPaste = true, clipboardOffered = false;
  late final client = BotDisplayClient(
    incoming: input.stream,
    send: accept,
    disconnect: () {
      closed = true;
      unawaited(input.close());
    },
  );
  void add(List<int> bytes) {
    if (closed) return;
    if (fragment) {
      for (final b in bytes) {
        input.add([b]);
      }
    } else {
      input.add(bytes);
    }
  }

  void begin() {
    add(ascii.encode('RFB 003.008\n'));
  }

  void accept(Uint8List bytes) {
    sent.add(Uint8List.fromList(bytes));
    if (phase == 0) {
      if (!listEquals(bytes, ascii.encode('RFB 003.008\n'))) {
        throw StateError('Invalid RFB client version');
      }
      phase++;
      add([1, 1]);
    } else if (phase == 1) {
      if (!listEquals(bytes, [1])) {
        throw StateError('Invalid RFB authentication selection');
      }
      phase++;
      add([0, 0, 0, 0]);
    } else if (phase == 2) {
      if (!listEquals(bytes, [1])) {
        throw StateError('RFB viewer must share the display');
      }
      phase++;
      final init = ByteData(24)
        ..setUint16(0, width)
        ..setUint16(2, height);
      add(init.buffer.asUint8List());
    } else if (bytes[0] == 2) {
      final data = ByteData.sublistView(bytes);
      final encodings = [
        for (var i = 0; i < data.getUint16(2); i++) data.getUint32(4 + i * 4),
      ];
      // TigerVNC encodings.h: -308 is ExtendedDesktopSize, not clipboard.
      // A real peer answers that request before delivering framebuffer pixels.
      if (encodings.contains(0xfffffecc)) {
        final desktop = ByteData(36)
          ..setUint16(2, 1)
          ..setUint16(8, width)
          ..setUint16(10, height)
          ..setInt32(12, -308)
          ..setUint8(16, 1)
          ..setUint16(28, width)
          ..setUint16(30, height);
        add(desktop.buffer.asUint8List());
      }
      // Only advertise the extension the client actually negotiated.
      if (!encodings.contains(0xc0a1e5ce)) return;
      final caps = ByteData(16)
        ..setUint8(0, 3)
        ..setInt32(4, -8)
        ..setUint32(8, 0x1f000001)
        ..setUint32(12, 256 * 1024);
      add(caps.buffer.asUint8List());
    } else if (bytes[0] == 6) {
      final data = ByteData.sublistView(bytes);
      if (data.getInt32(4) < 0 && data.getUint32(8) == 0x08000001) {
        clipboardOffered = true;
      }
    } else if (bytes[0] == 4 &&
        bytes[1] == 1 &&
        ByteData.sublistView(bytes).getUint32(4) == 0x76 &&
        clipboardOffered &&
        requestClipboardOnPaste) {
      requestClipboard();
    } else if (bytes[0] == 3) {
      requests++;
      if (requests == 1 && width * height < 100000) raw();
    }
  }

  void requestClipboard() {
    final request = ByteData(12)
      ..setUint8(0, 3)
      ..setInt32(4, -4)
      ..setUint32(8, 0x02000001);
    add(request.buffer.asUint8List());
  }

  void raw() {
    final header = ByteData(16)
      ..setUint16(2, 1)
      ..setUint16(8, width)
      ..setUint16(10, height);
    add([
      ...header.buffer.asUint8List(),
      for (var i = 0; i < width * height; i++) ...[i * 17 % 256, 90, 130, 0],
    ]);
  }
}

class DisplayFixture {
  final roster = BotsFixture();
  final peers = <DisplayPeer>[];
  final calls = <(String, String, Map<String, dynamic>)>[];
  String viewer = 'phone-viewer';
  String holder = 'agent';
  String? held;
  int epoch = 0, retains = 0, releases = 0;
  bool running = true,
      installed = true,
      failRelease = false,
      failStatus = false;
  Completer<void>? acquireWait, beforeAcquire, statusWait, connectWait;
  Map<String, dynamic> get lease => {
    'holder': holder,
    'epoch': epoch,
    'viewer_hash': held == null
        ? null
        : sha256.convert(utf8.encode(held!)).toString().substring(0, 12),
  };
  Map<String, dynamic> get status => {
    'supported': true,
    'installed': installed,
    if (!installed)
      'install_command': 'sudo apt install tigervnc-standalone-server',
    'running': running,
    'lease': lease,
  };
  late final repository = BotsRepository(
    groupObservations: GroupObservations(roster.repository.scope),
    scope: roster.repository.scope,
    instance: 'Home server',
    retain: () {
      retains++;
    },
    release: () {
      releases++;
    },
    read: (profile, method, params) async {
      calls.add((
        profile,
        method,
        Map<String, dynamic>.from(jsonDecode(jsonEncode(params))),
      ));
      if (method == 'display.status') {
        await statusWait?.future;
        if (failStatus) throw StateError('Offline');
        return status;
      }
      if (method == 'display.observe') {
        return {
          ...status,
          'ticket': 'one-use',
          'viewer_id': viewer,
          'path': '/api/display/ws',
        };
      }
      return roster.read(profile, method, params);
    },
    command: (profile, method, params, canDispatch, onDispatched) async {
      if (method == 'display.lease.acquire') await beforeAcquire?.future;
      if (!canDispatch()) throw StateError('Retired');
      onDispatched();
      calls.add((
        profile,
        method,
        Map<String, dynamic>.from(jsonDecode(jsonEncode(params))),
      ));
      if (method == 'display.lease.acquire') {
        await acquireWait?.future;
        holder = 'human';
        held = params['viewer_id'] as String;
        epoch++;
      } else if (method == 'display.lease.release') {
        if (failRelease) throw StateError('Offline');
        if (params['force'] != true &&
            params['viewer_id'] != held &&
            holder == 'human') {
          throw StateError('viewer_mismatch');
        }
        holder = 'agent';
        held = null;
        epoch++;
      } else if (method == 'display.start' || method == 'display.stop') {
        running = method == 'display.start';
      } else {
        throw StateError('Unexpected command');
      }
      return {...status, 'lease': lease};
    },
    displayConnect: (_) async {
      await connectWait?.future;
      final peer = DisplayPeer();
      peers.add(peer);
      final client = peer.client;
      peer.begin();
      return client;
    },
    ownership: roster.ownership,

  );
}
