import 'dart:async';
import 'dart:developer' as developer;
import 'dart:isolate';

import 'markdown_inline_parser.dart';
import 'markdown_segments.dart';
import 'performance_instrumentation.dart';

class MarkdownParseResult {
  const MarkdownParseResult(
    this.segments,
    this.parseMicros,
    this.cacheHits,
    this.inlineParses, {
    this.fenceMicros = 0,
  });
  final List<MarkdownSegment> segments;
  final int parseMicros;
  final int cacheHits;
  final int inlineParses;
  final int fenceMicros;
}

/// One lazy isolate prepares fences and prose for mounted messages. Widgets
/// coalesce updates, so each owner has at most one in-flight snapshot.
class MarkdownParseWorker {
  static MarkdownParseWorker? _shared;
  static MarkdownParseWorker get shared {
    if (_shared == null || _shared!._closed) _shared = MarkdownParseWorker();
    return _shared!;
  }

  final _requests = <int, (int, Completer<MarkdownParseResult>)>{};
  final _queue = <int, List<Object>>{};
  final _owners = <int>{};
  final _messages = ReceivePort();
  final _ready = Completer<SendPort>();
  Isolate? _isolate;
  Future<SendPort>? _starting;
  StreamSubscription<Object?>? _subscription;
  SendPort? _send;
  var _nextRequest = 0;
  var _closed = false;
  int? _active;

  Future<SendPort> _start() async {
    // Disposal can finish readiness while Isolate.spawn is still pending.
    // Attach an error handler now; awaiting the same future below still fails.
    _ready.future.ignore();
    _subscription = _messages.listen((message) {
      if (message is SendPort) {
        _send = message;
        if (!_ready.isCompleted) _ready.complete(message);
      } else if (message is List &&
          message.length == 3 &&
          message[0] == 'result') {
        _requests
            .remove(message[1])
            ?.$2
            .complete(message[2] as MarkdownParseResult);
        _queue.remove(message[1]);
        _active = null;
        _pump();
      } else if (message is List &&
          message.length == 2 &&
          message[0] == 'failed') {
        _requests
            .remove(message[1])
            ?.$2
            .completeError(StateError('Markdown parsing failed.'));
        _queue.remove(message[1]);
        _active = null;
        _pump();
      } else {
        // Isolate errors and exit notifications contain no exported diagnostics.
        _close();
      }
    });
    try {
      final isolate = await Isolate.spawn(
        _parseLoop,
        _messages.sendPort,
        debugName: 'wing-markdown-parser',
        onError: _messages.sendPort,
        onExit: _messages.sendPort,
      );
      if (_closed) {
        isolate.kill(priority: Isolate.immediate);
        throw StateError('Markdown worker is closed.');
      }
      _isolate = isolate;
      return await _ready.future;
    } catch (_) {
      _close();
      rethrow;
    }
  }

  Future<MarkdownParseResult> parse({
    required int owner,
    required String source,
    required bool deliverables,
    bool cacheEnabled = true,
    bool guardCode = true,
  }) {
    if (_closed) return Future.error(StateError('Markdown worker is closed.'));
    _owners.add(owner);
    final id = ++_nextRequest;
    final result = Completer<MarkdownParseResult>();
    _requests[id] = (owner, result);
    _queue[id] = [
      'parse',
      id,
      owner,
      source,
      deliverables,
      cacheEnabled,
      guardCode,
    ];
    _dispatch();
    return result.future;
  }

  Future<void> _dispatch() async {
    try {
      await (_starting ??= _start());
      _pump();
    } catch (_) {
      _close();
    }
  }

  void _pump() {
    if (_closed || _send == null || _active != null || _queue.isEmpty) return;
    final entry = _queue.entries.first;
    _active = entry.key;
    _send!.send(entry.value);
  }

  void release(int owner) {
    _owners.remove(owner);
    for (final entry in _requests.entries.toList()) {
      if (entry.value.$1 == owner) {
        _queue.remove(entry.key);
        _requests
            .remove(entry.key)
            ?.$2
            .completeError(StateError('Markdown request canceled.'));
      }
    }
    _send?.send(['release', owner]);
    if (_owners.isEmpty) _close();
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    for (final request in _requests.values) {
      request.$2.completeError(StateError('Markdown worker is closed.'));
    }
    _requests.clear();
    _queue.clear();
    _owners.clear();
    _isolate?.kill(priority: Isolate.immediate);
    _subscription?.cancel();
    _messages.close();
    if (_starting != null && !_ready.isCompleted) {
      // _start may still be spawning; its own continuation kills a late isolate.
      _ready.completeError(StateError('Markdown worker is closed.'));
    }
  }

  Future<void> dispose() async {
    _close();
    try {
      await _starting;
    } catch (_) {
      // Pending requests already received the sanitized lifecycle error.
    }
  }
}

void _parseLoop(SendPort replies) {
  final inbox = ReceivePort();
  final owners = <int, _OwnerPreparation>{};
  replies.send(inbox.sendPort);
  inbox.listen((dynamic message) {
    final values = message as List;
    if (values[0] == 'release') {
      owners.remove(values[1])?.clear();
      return;
    }
    final id = values[1] as int;
    try {
      final owner = values[2] as int;
      final configuration = (
        values[4] as bool,
        values[5] as bool,
        values[6] as bool,
      );
      final existing = owners[owner];
      final preparation = existing?.configuration == configuration
          ? existing!
          : _OwnerPreparation(configuration);
      if (!identical(existing, preparation)) {
        existing?.clear();
      }
      owners[owner] = preparation;
      if (PerformanceInstrumentation.enabled) {
        developer.Timeline.startSync('wing.markdown.prepare');
      }
      late final MarkdownParseResult result;
      try {
        result = preparation.prepare(values[3] as String);
      } finally {
        if (PerformanceInstrumentation.enabled) {
          developer.Timeline.finishSync();
        }
      }
      replies.send(['result', id, result]);
    } catch (_) {
      replies.send(['failed', id]);
    }
  });
}

class _ParsedProse {
  _ParsedProse(this.parser);

  final MarkdownInlineParser parser;
  MarkdownProseSegment? accepted;
}

class _OwnerPreparation {
  _OwnerPreparation(this.configuration);

  final (bool, bool, bool) configuration;
  final _prose = <int, _ParsedProse>{};

  MarkdownParseResult prepare(String source) {
    final fenceClock = PerformanceInstrumentation.enabled
        ? (Stopwatch()..start())
        : null;
    if (PerformanceInstrumentation.enabled) {
      developer.Timeline.startSync('wing.markdown.fence.scan');
    }
    late final List<MarkdownSegment> scanned;
    try {
      scanned = splitMarkdownSegments(source);
    } finally {
      if (PerformanceInstrumentation.enabled) {
        fenceClock!.stop();
        developer.Timeline.finishSync();
      }
    }
    final prepared = <MarkdownSegment>[];
    final used = <int>{};
    var parseMicros = 0;
    var cacheHits = 0;
    var inlineParses = 0;
    for (final (index, segment) in scanned.indexed) {
      if (segment is MarkdownFenceSegment) {
        prepared.add(segment);
        continue;
      }
      final prose = segment as MarkdownProseSegment;
      used.add(index);
      final state = _prose.putIfAbsent(
        index,
        () => _ParsedProse(
          MarkdownInlineParser(
            deliverables: configuration.$1,
            cacheEnabled: configuration.$2,
            guardCode: configuration.$3,
          ),
        ),
      );
      if (state.accepted?.source == prose.source) {
        prepared.add(state.accepted!);
        continue;
      }
      final nodes = state.parser.parse(prose.source);
      final parsed = state.accepted = MarkdownProseSegment(
        source: prose.source,
        nodes: nodes,
      );
      prepared.add(parsed);
      if (PerformanceInstrumentation.enabled) {
        parseMicros += state.parser.lastParseMicros;
        cacheHits += state.parser.cacheHits;
        inlineParses += state.parser.inlineParses;
      }
    }
    for (final index in _prose.keys.toList()) {
      if (!used.contains(index)) {
        _prose.remove(index)!.parser.clear();
      }
    }
    return MarkdownParseResult(
      prepared,
      parseMicros,
      cacheHits,
      inlineParses,
      fenceMicros: PerformanceInstrumentation.enabled
          ? fenceClock!.elapsedMicroseconds
          : 0,
    );
  }

  void clear() {
    for (final state in _prose.values) {
      state.parser.clear();
    }
    _prose.clear();
  }
}
