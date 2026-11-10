import 'dart:async';
import '../models/operational_error.dart';
import 'package:flutter/foundation.dart';
import '../models/bots.dart';
import '../models/bot_display.dart';
import 'bots_repository.dart';
import 'bot_display_client.dart';

/// Owns the visible stream, connection-bound viewer and confirmed control lease.
/// Background/disconnection keeps the human lease; an explicit exit releases it.
class BotScreenSession extends ChangeNotifier {
  BotScreenSession(this.repository, this.bot, {this.onOperationalError}) {
    repository.retain();
  }
  final BotsRepository repository;
  final BotRecord bot;
  final OperationalErrorReporter? onOperationalError;

  void _reportStream(String? error) => onOperationalError?.call(
    OperationalErrorObservation(
      connectionIdentity: bot.scope.connectionIdentity,
      profileName: bot.scope.profileName,
      operation: 'bot-screen:${bot.id}',
      title: 'Bot screen unavailable',
      error: error,
    ),
  );
  BotDisplayStatus? _status;
  BotDisplayStatus? get status => _status;
  BotDisplayLease? _lease;
  BotDisplayFrame? _frame;
  BotDisplayFrame? get frame => _frame;
  String? _error, _viewer, _heldViewer;
  String? get error => _error;
  BotDisplayClient? _client;
  StreamSubscription<BotDisplayFrame>? _subscription;
  Timer? _poll;
  Future<void>? _operation;
  bool _visible = false, _disposed = false, _closing = false, _closed = false;
  bool _requestedVisible = false;
  bool _focused = true;
  bool _connected = false, _changingControl = false;
  int _generation = 0, _inputRevision = 0;
  int _pointerX = 0, _pointerY = 0;
  bool get busy => _operation != null || _closing;
  bool get connected => _connected;
  bool get connecting => _client != null && !_connected;
  bool get controlling => _lease?.ownedBy(_viewer) == true;
  bool get canInput =>
      controlling &&
      connected &&
      _visible &&
      _focused &&
      !_changingControl &&
      !_closing &&
      !_closed;
  bool get humanHasControl => _lease?.holder == 'human';
  bool get canStart =>
      _status != null &&
      _status!.supported &&
      _status!.installed &&
      !_status!.running &&
      _status!.blocker == null &&
      !busy;
  bool get canStop =>
      _status?.running == true && _lease?.holder == 'agent' && !busy;
  bool get canTakeOver => connected && !busy && _visible && _focused;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void setVisible(bool visible) {
    _requestedVisible = visible;
    if (_closed || _closing) return;
    if (_visible == visible && (visible ? _poll != null : _client == null)) {
      return;
    }
    _visible = visible;
    _poll?.cancel();
    if (!visible) {
      _generation++;
      _dropStream();
    } else {
      unawaited(refresh());
      _poll = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(refresh()),
      );
    }
    _changed();
  }

  void setFocused(bool focused) {
    if (_focused == focused) return;
    if (!focused && canInput) _client?.pointer(_pointerX, _pointerY, 0);
    if (!focused) _inputRevision++;
    _focused = focused;
    _changed();
  }

  void _dropStream() {
    if (_connected) _client?.pointer(_pointerX, _pointerY, 0);
    _connected = false;
    _frame = null;
    _lease =
        null; // No local input authority while the observation is uncertain.
    unawaited(_subscription?.cancel());
    _subscription = null;
    _client?.close();
    _client = null;
  }

  Future<void> _run(
    Future<void> Function() work, {
    int? streamGeneration,
  }) async {
    if (busy || _closed) return;
    final done = Completer<void>();
    _operation = done.future;
    _changed();
    try {
      await work();
    } catch (_) {
      if (!_closed &&
          !_closing &&
          (streamGeneration == null ||
              _visible && streamGeneration == _generation)) {
        _error =
            'Screen connection could not be confirmed. Refresh to retry. '
            'If you took control, it stays held until you hand it back.';
        if (streamGeneration != null) _reportStream(_error);
        _dropStream();
      }
    } finally {
      _operation = null;
      done.complete();
      _changed();
    }
  }

  /// An explicit refresh waits for a quiet poll instead of silently doing nothing.
  Future<void> refreshScreen() async {
    await _operation;
    if (!_closed && !_closing) await refresh();
  }

  Future<void> refresh() {
    final generation = _generation;
    return _run(() async {
      if (!_visible) return;
      bool active() =>
          !_closed && !_closing && _visible && generation == _generation;
      final status = await repository.displayStatus(bot);
      if (!active()) return;
      final stopped = _status?.running != false || _error != null;
      _status = status;
      _lease = status.lease;
      _error = null;
      if (!status.running) {
        if (stopped) _reportStream(null);
        _dropStream();
        _lease = status.lease;
        return;
      }
      if (_client != null) return;
      final observation = await repository.observeDisplay(bot, _viewer);
      if (!active()) return;
      _viewer = observation.viewer;
      _status = observation.status;
      _lease = observation.status.lease;
      final client = await repository.connectDisplay(observation.ticket);
      if (!active()) {
        client.close();
        return;
      }
      _client = client;
      _subscription = client.frames.listen(
        (frame) {
          if (!active() || !identical(client, _client)) return;
          _frame = frame;
          final firstFrame = !_connected;
          _connected = true;
          if (firstFrame) _reportStream(null);
          _changed();
        },
        onError: (Object error) {
          if (identical(client, _client)) {
            _generation++;
            _dropStream();
            _error =
                'Screen disconnected. Control stays held until you hand it back.';
            _reportStream(_error);
            _changed();
          }
        },
        onDone: () {
          if (identical(client, _client)) {
            _generation++;
            _dropStream();
            _error = 'Screen disconnected. Refresh to reconnect.';
            _reportStream(_error);
            _changed();
          }
        },
      );
      client.start();
    }, streamGeneration: generation);
  }

  Future<void> power(bool start) =>
      _run(() async {
        if (start
            ? !(_status?.supported == true &&
                  _status?.installed == true &&
                  _status?.running == false &&
                  _status?.blocker == null)
            : !(_status?.running == true && _lease?.holder == 'agent')) {
          return;
        }
        await repository.screenPower(
          bot,
          start,
          () => !_closed && !_closing && _visible,
          () {},
        );
        _generation++;
        _dropStream();
        final status = await repository.displayStatus(bot);
        if (!_closed && !_closing) {
          _status = status;
          _lease = status.lease;
          _error = null;
        }
      }).then((_) {
        if (_visible && !_closing && !_closed) unawaited(refresh());
      });

  Future<void> takeOver() {
    if (!canTakeOver) return Future.value();
    final viewer = _viewer!, generation = _generation;
    _changingControl = true;
    return _run(() async {
      final lease = await repository.displayControl(
        bot,
        viewer,
        acquire: true,
        force: false,
        canDispatch: () =>
            !_closed &&
            !_closing &&
            _visible &&
            _focused &&
            connected &&
            generation == _generation,
        onDispatched: () {
          _heldViewer = viewer;
        },
      );
      if (!_closed && !_closing && _visible && generation == _generation) {
        _lease = lease;
        _error = null;
      }
    }).whenComplete(() {
      _changingControl = false;
      _changed();
    });
  }

  Future<void> handBack({bool force = false}) {
    if (busy || _closed) return Future.value();
    if (canInput) _client?.pointer(_pointerX, _pointerY, 0);
    _changingControl = true;
    return _run(() async {
      // Force is only sent following the view's explicit confirmation.
      final viewer = _heldViewer ?? _viewer;
      final lease = await repository.displayControl(
        bot,
        viewer,
        acquire: false,
        force: force,
        canDispatch: () => !_closed && !_closing && _visible,
        onDispatched: () {},
      );
      if (!_closed && !_closing) {
        _lease = lease;
        _heldViewer = null;
        _error = null;
      }
    }).whenComplete(() {
      _changingControl = false;
      _changed();
    });
  }

  void pointer(int x, int y, int buttons) {
    if (canInput) {
      _pointerX = x;
      _pointerY = y;
      _client?.pointer(x, y, buttons);
    }
  }

  void scroll(bool up) {
    pointer(_pointerX, _pointerY, up ? 8 : 16);
    pointer(_pointerX, _pointerY, 0);
  }

  void key(int keysym, {Set<int> modifiers = const {}}) {
    if (!canInput) return;
    for (final modifier in modifiers) {
      _client?.key(modifier, true);
    }
    _client?.key(keysym, true);
    _client?.key(keysym, false);
    for (final modifier in modifiers.toList().reversed) {
      _client?.key(modifier, false);
    }
  }

  void typeText(String text, {Set<int> modifiers = const {}}) {
    if (!canInput) return;
    for (final rune in text.runes) {
      key(
        rune == 10
            ? 0xff0d
            : rune == 9
            ? 0xff09
            : rune <= 255
            ? rune
            : 0x01000000 | rune,
        modifiers: modifiers,
      );
    }
  }

  bool _pasting = false;
  bool get pasting => _pasting;

  Future<void> pasteClipboard(Future<String?> Function() readClipboard) async {
    if (!canInput || _pasting) return;
    final client = _client!,
        generation = _generation,
        lease = _lease,
        inputRevision = _inputRevision;
    _pasting = true;
    _changed();
    try {
      final text = await readClipboard();
      bool admitted() =>
          canInput &&
          generation == _generation &&
          inputRevision == _inputRevision &&
          identical(client, _client) &&
          _lease?.epoch == lease?.epoch;
      if (!admitted()) {
        throw StateError('Control changed. Take control before pasting.');
      }
      if (text == null || text.isEmpty) {
        throw StateError('The phone clipboard has no text.');
      }
      await client.pasteClipboard(text, canProvide: admitted);
    } finally {
      _pasting = false;
      _changed();
    }
  }

  Future<bool>? _exit;
  Future<bool> close() => _exit ??= _close().whenComplete(() {
    _exit = null;
  });
  Future<bool> _close() async {
    if (_closed) return true;
    _closing = true;
    _visible = false;
    _generation++;
    _poll?.cancel();
    _dropStream();
    _changed();
    await _operation;
    try {
      final held = _heldViewer;
      if (held != null) {
        // Wait for an already-dispatched acquisition, then release only our id.
        // Never force-release another controller as part of route cleanup.
        try {
          await repository.displayControl(
            bot,
            held,
            acquire: false,
            force: false,
            canDispatch: () => true,
            onDispatched: () {},
          );
        } catch (_) {
          // Another device may have taken over, or our RPC connection may have
          // been replaced. A confirmed different holder needs no cleanup.
          final current = await repository.displayStatus(bot);
          if (current.lease.ownedBy(held)) rethrow;
        }
        _heldViewer = null;
      }
    } catch (_) {
      _closing = false;
      _error =
          'Control could not be handed back. Reconnect and hand it back before closing.';
      if (!_disposed) setVisible(_requestedVisible);
      _changed();
      return false;
    }
    _closed = true;
    _closing = false;
    repository.release();
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(
      close().then((closed) {
        // A destroyed route cannot retry. Preserve the lease and end local ownership.
        if (!closed && !_closed) {
          _closed = true;
          repository.release();
        }
      }),
    );
    super.dispose();
  }
}
