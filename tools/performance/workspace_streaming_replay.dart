import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/connection_access.dart';
// Offline profile fixture. Native draft storage is excluded: preferences use
// an isolated in-memory store. Rendering, controller events and composer input
// run through the real workspace. No gateway performs network requests.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:ui' show FramePhase, FrameTiming, ViewPadding;

import 'package:flutter/foundation.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/performance_instrumentation.dart';
import 'package:wing/core/services/completion_diagnostics.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/background_markdown_content.dart';
import 'package:wing/core/widgets/block_reusing_markdown_body.dart';
import 'package:wing/core/widgets/markdown_code_block.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';

import '../../test/support/profile_browser_fixture.dart';
import 'streaming_replay_fixture.dart';

const workspaceReplayDeltaCount = 400;
const workspaceReplayIntervalUs = 50000;

bool workspaceReplayMatchesSegments(
  String source,
  Iterable<Widget> widgets, {
  required bool streaming,
}) {
  final expected = splitMarkdownCodeBlocks(source, streaming: streaming)
      .map(
        (part) =>
            part is MarkdownCodeBlock ? ('code', part.code) : ('prose', part),
      )
      .toList();
  final actual = widgets
      .where(
        (widget) =>
            widget is BlockReusingMarkdownBody || widget is MarkdownCodeBlock,
      )
      .map(
        (widget) => widget is MarkdownCodeBlock
            ? ('code', widget.code)
            : ('prose', (widget as BlockReusingMarkdownBody).data),
      )
      .toList();
  return listEquals(expected, actual);
}

void main() {
  if (!PerformanceInstrumentation.enabled) {
    throw StateError(
      'Build with --dart-define=WING_PERF_INSTRUMENTATION=true.',
    );
  }
  if (!kProfileMode) {
    throw StateError('Workspace replay requires profile mode');
  }
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      theme: wingTheme(Brightness.light),
      home: const WorkspaceStreamingReplay(),
    ),
  );
}

class _ReplayGateway extends ProfileBrowserFixture {
  _ReplayGateway({int? historyCount, this.work = false})
    : rows = historyCount == null
          ? [
              {
                'id': 1,
                'role': 'user',
                'content': 'Show the fixed synthetic mixed answer.',
              },
            ]
          : [
              for (var index = 1; index <= historyCount; index++)
                {
                  'id': index,
                  'role': index.isOdd ? 'user' : 'assistant',
                  'content': 'Offline synthetic history row $index.',
                },
            ];

  List<Map<String, dynamic>> rows;
  final bool work;
  final _createdAt = DateTime.now().millisecondsSinceEpoch / 1000;
  double? _readAt;
  int readReceiptWrites = 0;
  List<Map<String, dynamic>> get agents => [
    if (work)
      for (var index = 0; index < 2; index++)
        {
          'subagent_id': 'offline-agent-$index',
          'goal': 'Inspect synthetic section $index',
          'status': 'running',
        },
  ];
  String? liveSource;

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: base.discover,
      connect: base.connect,
      close: base.close,
      get: base.read,
      ownedPatch: (path, body, canDispatch, onDispatched) async {
        if (!canDispatch() ||
            path != 'sessions/new-chat' ||
            body.length != 2 ||
            body['profile'] != scope.profileName ||
            body['unread'] != false) {
          throw StateError('Invalid offline read acknowledgement');
        }
        onDispatched();
        _readAt = DateTime.now().millisecondsSinceEpoch / 1000;
        readReceiptWrites++;
        return {'ok': true};
      },
      rpc: (method, params) async {
        if (method == 'subagent.list') return {'subagents': agents};
        final response = await base.call(method, params);
        if (method != 'session.resume') return response;
        return {
          ...response,
          'running': liveSource != null,
          if (liveSource != null) 'inflight': {'assistant': liveSource},
        };
      },
    );
  }

  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) => rows;

  @override
  List<Map<String, dynamic>> projects(String profile) => [];

  @override
  List<Map<String, dynamic>> sessions(String profile) => [
    {
      'id': 'new-chat',
      'title': 'Offline workspace replay',
      'profile': profile,
      'last_active': _createdAt,
      if (_readAt != null) 'last_read_at': _readAt,
    },
  ];
}

class WorkspaceStreamingReplay extends StatefulWidget {
  const WorkspaceStreamingReplay({super.key});

  @override
  WorkspaceStreamingReplayState createState() =>
      WorkspaceStreamingReplayState();
}

class WorkspaceStreamingReplayState extends State<WorkspaceStreamingReplay>
    with WidgetsBindingObserver {
  ProfileWorkspaceController? controller;
  final _pendingRetiredControllers = <ProfileWorkspaceController>{};
  AppPreferences? _appPreferences;
  ProfileChat? _chat;
  _ReplayGateway? _fixture;
  ProfileGateway? _gateway;
  EditableTextState? _composer;
  final _frames = <FrameTiming>[];
  Completer<void>? _abort;
  var _canceled = false;
  var _preparing = false;
  var _running = false;
  var _prepared = false;
  var _collecting = false;
  var _run = 0;
  var _replyTurn = 0;
  var _replySegment = 0;
  var _replyOffset = 0;
  ProfileWorkspaceController? _probeOwner;
  Stopwatch? _probeWatch;
  var _probeNotifications = 0;
  var _probing = false;
  int? _idleHistoryCount;
  (Size, ViewPadding, double, double)? _probeGeometry;
  bool _probeFocusAtStart = false;

  Map<String, Object?> ready() => {
    'prepared': _prepared,
    'preparing': _preparing,
    'running': _running,
    'keyboard': mounted && View.of(context).viewInsets.bottom > 0,
    'composerFocused': _composer?.widget.focusNode.hasFocus ?? false,
    'draft': _chat?.composer.observation.displayedText,
    'sourceCharacters': _chat?.reading.streaming.length ?? 0,
    'execution': _chat?.runtime.execution.name,
    'selectedChatMatches': identical(controller?.current?.chat, _chat),
    'runtimeId': _chat?.runtime.runtimeId,
    'nativeDraftStorage': false,
    'readReceiptWrites': _fixture?.readReceiptWrites ?? 0,
    'markReadFailed': _chat?.markReadFailed ?? false,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addTimingsCallback(_timings);
    if (kProfileMode) {
      for (final action in [
        'ready',
        'prepare',
        'controls',
        'replay',
        'recordedFrames',
        'prepareIdle',
        'startProbe',
        'stopProbe',
      ]) {
        developer.registerExtension('ext.wingReplay.$action', (
          _,
          parameters,
        ) async {
          try {
            final result = switch (action) {
              'prepare' => await prepare(work: parameters['work'] == 'true'),
              'controls' => controls(),
              'recordedFrames' => recordedFrames(),
              'replay' => await replay(
                label: parameters['label'] ?? '',
                keyboardOpen: parameters['keyboard'] != 'closed',
              ),
              'prepareIdle' => await prepareIdle(
                int.tryParse(parameters['historyCount'] ?? '') ?? -1,
              ),
              'startProbe' => startProbe(),
              'stopProbe' => await stopProbe(),
              _ => ready(),
            };
            return developer.ServiceExtensionResponse.result(
              jsonEncode(result),
            );
          } catch (error) {
            return developer.ServiceExtensionResponse.error(
              developer.ServiceExtensionResponse.extensionError,
              error.toString(),
            );
          }
        });
      }
    }
  }

  void _timings(List<FrameTiming> frames) {
    if (_collecting) {
      _frames.addAll(frames);
    }
  }

  /// Includes the settling tail already collected after the replay's budget
  /// window. Read only after measurement, so delayed work cannot hide a hitch.
  Map<String, Object> recordedFrames() {
    if (_running || _preparing || _probing) {
      throw StateError('Frame recording is still in progress');
    }
    return {
      'frames': [
        for (final frame in _frames)
          {
            'startUs': frame.timestampInMicroseconds(FramePhase.buildStart),
            'buildUs': frame.buildDuration.inMicroseconds,
            'rasterUs': frame.rasterDuration.inMicroseconds,
          },
      ],
    };
  }

  void _countProbeNotification() => _probeNotifications++;

  void _requireMounted() {
    if (!mounted) {
      throw StateError('Replay unmounted');
    }
    if (_canceled) {
      throw StateError('Replay canceled by lifecycle change');
    }
    if (_running && !identical(controller?.current?.chat, _chat)) {
      throw StateError('Selected replay chat changed');
    }
    if (_running &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      throw StateError('Replay must remain in the foreground');
    }
  }

  double _textScaleAt14() {
    _requireMounted();
    return MediaQuery.textScalerOf(context).scale(14);
  }

  Future<void> _wait(Duration duration) async {
    final done = Completer<void>();
    final timer = Timer(duration, done.complete);
    try {
      await Future.any([done.future, if (_abort != null) _abort!.future]);
    } finally {
      timer.cancel();
    }
    _requireMounted();
  }

  Future<void> _endFrame() async {
    _requireMounted();
    final timeout = Completer<void>();
    final timer = Timer(
      const Duration(seconds: 3),
      () => timeout.completeError(
        StateError('Frame wait exceeded three seconds'),
      ),
    );
    WidgetsBinding.instance.scheduleFrame();
    try {
      await Future.any([
        WidgetsBinding.instance.endOfFrame,
        timeout.future,
        if (_abort != null) _abort!.future,
      ]);
    } finally {
      timer.cancel();
    }
    _requireMounted();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed ||
        (!_preparing && !_running && !_prepared)) {
      return;
    }
    _canceled = true;
    _prepared = false;
    if (_probing) _clearProbe();
    if (_abort case final abort? when !abort.isCompleted) {
      abort.complete();
    }
  }

  Iterable<Element> _walk(Element element) sync* {
    if (element.widget case Offstage(offstage: true)) {
      return;
    }
    yield element;
    final children = <Element>[];
    element.visitChildren(children.add);
    for (final child in children) {
      yield* _walk(child);
    }
  }

  Iterable<Widget> _segmentWidgets(Element element) sync* {
    final widget = element.widget;
    if (widget is Offstage && widget.offstage) return;
    if (widget is BlockReusingMarkdownBody || widget is MarkdownCodeBlock) {
      // A logical segment owns its rendering. Adaptive table cells inside a
      // prose segment are descendants, not additional document segments.
      yield widget;
      return;
    }
    final children = <Element>[];
    element.visitChildren(children.add);
    for (final child in children) {
      yield* _segmentWidgets(child);
    }
  }

  // Called only before measurement or after the completion tail.
  Map<String, Object> renderedReadiness(String source) {
    final bodies = _walk(context as Element)
        .where(
          (element) =>
              element.widget is MarkdownMessageContent &&
              (element.widget as MarkdownMessageContent).data == source,
        )
        .toList();
    final elements = bodies.length == 1
        ? _walk(bodies.single).toList()
        : <Element>[];
    final parsers = elements
        .whereType<StatefulElement>()
        .map((element) => element.state)
        .whereType<BackgroundMarkdownContentState>()
        .toList();
    final marker = source.contains('Synthetic11_44')
        ? 'Synthetic11_44'
        : 'Synthetic5_44';
    final segmentsMatch = workspaceReplayMatchesSegments(
      source,
      bodies.length == 1 ? _segmentWidgets(bodies.single) : const [],
      streaming: _chat!.runtime.blocksTurnAdmission,
    );
    var editableMarkers = 0;
    var paragraphMarkers = 0;
    for (final element in elements.whereType<RenderObjectElement>()) {
      final render = element.renderObject;
      if (render is RenderEditable &&
          render.hasSize &&
          (render.text?.toPlainText().contains(marker) ?? false)) {
        editableMarkers++;
      } else if (render is RenderParagraph &&
          render.hasSize &&
          render.text.toPlainText().contains(marker)) {
        paragraphMarkers++;
      }
    }
    final pending = parsers.where((state) => state.pending).length;
    final stale = parsers
        .where((state) => state.renderedSource != state.widget.data)
        .length;
    return {
      'bodyCount': bodies.length,
      'expectedSegments': splitMarkdownCodeBlocks(
        source,
        streaming: _chat!.runtime.blocksTurnAdmission,
      ).length,
      'mountedProse': elements
          .where((element) => element.widget is BlockReusingMarkdownBody)
          .length,
      'mountedCode': elements
          .where((element) => element.widget is MarkdownCodeBlock)
          .length,
      'segmentsMatch': segmentsMatch,
      'parserCount': parsers.length,
      'pendingParsers': pending,
      'staleParsers': stale,
      'workerJobsCompleted': parsers.fold<int>(
        0,
        (sum, state) => sum + state.parsesCompleted,
      ),
      'workerFenceUs': parsers.fold<int>(
        0,
        (sum, state) => sum + state.totalFenceMicros,
      ),
      'workerParseUs': parsers.fold<int>(
        0,
        (sum, state) => sum + state.totalParserMicros,
      ),
      'workerRequestMaxUs': parsers.fold<int>(
        0,
        (maximum, state) => math.max(maximum, state.maxRequestMicros),
      ),
      'workerCoalescedUpdates': parsers.fold<int>(
        0,
        (sum, state) => sum + state.updatesCoalesced,
      ),
      'workerPendingCharactersMax': parsers.fold<int>(
        0,
        (maximum, state) => math.max(maximum, state.maxPendingCharacters),
      ),
      'editableMarkers': editableMarkers,
      'paragraphMarkers': paragraphMarkers,
      'rendered':
          bodies.length == 1 &&
          segmentsMatch &&
          parsers.isNotEmpty &&
          pending == 0 &&
          stale == 0 &&
          editableMarkers + paragraphMarkers > 0,
    };
  }

  bool _rendered(String source) =>
      renderedReadiness(source)['rendered'] == true;

  Future<void> _awaitRendered(String source) async {
    for (var attempt = 0; attempt < 150; attempt++) {
      await _endFrame();
      if (_rendered(source)) {
        return;
      }
      await _wait(const Duration(milliseconds: 20));
    }
    throw StateError(
      'Final renderer did not settle: ${jsonEncode(renderedReadiness(source))}',
    );
  }

  Future<void> _awaitIdleRendered() async {
    for (var attempt = 0; attempt < 150; attempt++) {
      await _endFrame();
      if (_idleRendererReady()) return;
      await _wait(const Duration(milliseconds: 20));
    }
    throw StateError('Idle history renderer did not settle');
  }

  void _emit(String type, Map<String, dynamic> data) {
    // The workspace's passive monitoring reads must observe the same synthetic
    // turn as its event stream, including while keyboard preparation settles.
    if (type == 'message.start') {
      _replyTurn++;
      _replySegment = 0;
      _replyOffset = 0;
      data = {...data, 'turn_id': 'offline-replay-turn-$_replyTurn'};
      _fixture!.liveSource = '';
      _fixture!.liveSessions[_chat!.key.workspace.profileName] = [
        {
          'id': _chat!.runtime.runtimeId,
          'session_key': _chat!.key.sessionId,
          'status': 'working',
          'last_active': _fixture!.now,
        },
      ];
    } else if (type == 'message.delta') {
      final text = data['text'];
      if (text is String) {
        data = {
          ...data,
          'turn_id': 'offline-replay-turn-$_replyTurn',
          'segment': _replySegment,
          'offset': _replyOffset,
        };
        // Stock offsets and Dart String.length both count UTF-16 code units.
        _replyOffset += text.length;
      }
      _fixture!.liveSource = '${_fixture!.liveSource ?? ''}${data['text']}';
    } else if (type == 'message.interim') {
      data = {
        ...data,
        'turn_id': 'offline-replay-turn-$_replyTurn',
        'segment': _replySegment,
      };
      _replySegment++;
      _replyOffset = 0;
    } else if (type == 'message.complete') {
      _fixture!.liveSource = null;
      _fixture!.liveSessions.clear();
    }
    _gateway!.onEvent!(
      StreamEvent(type: type, sessionId: _chat!.runtime.runtimeId, data: data),
    );
  }

  /// Host-driven chunks share the timed replay's stock identity cursor.
  void appendReply(String text) => _emit('message.delta', {'text': text});

  // The same stock completion receipt used by the timed replay. Host checks
  // can seal a prepared answer without waiting through the token schedule.
  void complete() {
    if (!_prepared || _running || _preparing || _idleHistoryCount != null) {
      throw StateError('Prepare a stream before completing it');
    }
    _prepared = false;
    _completeSource(_chat!.reading.streaming);
  }

  void _completeSource(String source) {
    _fixture!.rows = [
      ..._fixture!.rows,
      {'id': 2, 'role': 'assistant', 'content': source},
    ];
    _emit('message.complete', {
      'status': 'complete',
      'text': source,
      'persisted_turn': {
        'row_ids': [2],
        'complete': true,
        'final_assistant_row_id': 2,
      },
    });
  }

  // Tests may omit the physical keyboard precondition; the VM extension always
  // uses it. Preparation and renderer checks are outside measured intervals.
  Future<Map<String, Object?>> prepare({
    bool requireKeyboard = true,
    bool work = false,
  }) async {
    return _prepare(requireKeyboard: requireKeyboard, work: work);
  }

  Map<String, Object?> controls() {
    final result = <String, Object?>{};
    for (final element in _walk(context as Element)) {
      final name = switch (element.widget.key) {
        ValueKey(value: ('live-work-tab', 0, _)) => 'subagents',
        ValueKey(value: ('live-work-tab', 1, _)) => 'tasks',
        _ => switch (element.widget) {
          Text(data: 'Activity · 1 tool') => 'activity',
          _ => null,
        },
      };
      if (name == null) continue;
      final render = element.findRenderObject();
      if (render is! RenderBox || !render.hasSize) continue;
      final center = render.localToGlobal(render.size.center(Offset.zero));
      // Kept-alive sliver rows have no painted transform. Covered controls
      // likewise must not be advertised as physical tap targets.
      if (!center.dx.isFinite || !center.dy.isFinite) continue;
      final view = View.of(context);
      final ratio = view.devicePixelRatio;
      final point = [(center.dx * ratio).round(), (center.dy * ratio).round()];
      final hits = HitTestResult();
      WidgetsBinding.instance.hitTestInView(
        hits,
        Offset(point[0] / ratio, point[1] / ratio),
        view.viewId,
      );
      if (!hits.path.any((hit) => identical(hit.target, render))) continue;
      result[name] = point;
    }
    return result;
  }

  Future<Map<String, Object?>> prepareIdle(
    int historyCount, {
    bool requireKeyboard = true,
  }) async {
    if (historyCount != 2 && historyCount != 50) {
      throw StateError('Idle history must contain 2 or 50 rows');
    }
    return _prepare(
      requireKeyboard: requireKeyboard,
      historyCount: historyCount,
    );
  }

  Future<Map<String, Object?>> _prepare({
    required bool requireKeyboard,
    int? historyCount,
    bool work = false,
  }) async {
    if (_preparing || _running) {
      throw StateError('Replay already active');
    }
    _clearProbe();
    _preparing = true;
    _prepared = false;
    _canceled = false;
    _abort = Completer<void>();
    try {
      final old = controller;
      controller = null;
      _composer = null;
      if (old != null) _retireAfterDetachedFrame(old);
      setState(() {});
      await _endFrame();
      if (old != null) _disposeRetiredController(old);
      // This offline profile benchmark intentionally excludes native draft
      // storage and must never read or mutate the installed app's preferences.
      if (!mounted) throw StateError('Replay unmounted');
      // Journals remain sample-local: an old controller may finish a retained
      // reading-copy write after disposal. The device preference owner itself
      // is shared across the entire replay root and never replaces its store.
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      if (!mounted) throw StateError('Replay unmounted');
      _appPreferences ??= AppPreferences(preferences);
      final fixture = _fixture = _ReplayGateway(
        historyCount: historyCount,
        work: work,
      );
      _idleHistoryCount = historyCount;
      final next = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: SavedConnection(
            id: 'qa-render-replay',
            label: 'Offline replay',
            host: 'localhost',
            port: 1,
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'qa-render-replay',
        preferences: preferences,
        appPreferences: _appPreferences!,
        gatewayFactory: fixture.gateway,
      );
      controller = next;
      await next.initialize();
      if (!mounted) throw StateError('Replay unmounted');
      final resource = next.current;
      final preparation = _abort;
      _chat = await next.createChat(
        canDispatch: () =>
            mounted &&
            !_canceled &&
            _preparing &&
            identical(_abort, preparation) &&
            identical(controller, next) &&
            identical(next.current, resource),
      );
      if (!mounted) throw StateError('Replay unmounted');
      _gateway = next.current!.gateway;
      await next.refreshHistory(_chat!);
      if (!mounted) throw StateError('Replay unmounted');
      setState(() {});
      if (historyCount == null) {
        await _endFrame();
      } else {
        await _awaitIdleRendered();
      }
      if (!mounted) {
        throw StateError('Replay unmounted');
      }
      final composerRoot = _walk(context as Element)
          .where(
            (element) =>
                element.widget.key == const Key('profile-message-composer'),
          )
          .single;
      _composer = _walk(composerRoot)
          .whereType<StatefulElement>()
          .map((element) => element.state)
          .whereType<EditableTextState>()
          .single;
      _composer!.userUpdateTextEditingValue(
        const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        ),
        SelectionChangedCause.keyboard,
      );
      _composer!.widget.focusNode.requestFocus();
      await _endFrame();
      if (historyCount != null) {
        await _endFrame();
        await _wait(const Duration(milliseconds: 150));
        if (_chat!.runtime.blocksTurnAdmission ||
            _chat!.reading.streaming.isNotEmpty ||
            _chat!.composer.observation.displayedText.isNotEmpty ||
            _chat!.reading.messages.length != historyCount) {
          throw StateError('Idle history or composer did not settle');
        }
      }
      if (!mounted) {
        throw StateError('Replay unmounted');
      }
      if (requireKeyboard) {
        final view = View.of(context);
        var stable = 0;
        var previous = view.viewInsets;
        for (var attempt = 0; attempt < 30 && stable < 3; attempt++) {
          await _wait(const Duration(milliseconds: 100));
          final insets = view.viewInsets;
          stable =
              insets == previous &&
                  insets.bottom > 0 &&
                  _composer!.widget.focusNode.hasFocus
              ? stable + 1
              : 0;
          previous = insets;
        }
        if (stable < 3) {
          throw StateError('Focus the composer and open the keyboard');
        }
      }
      if (historyCount == null) {
        _emit('message.start', {});
        if (work) {
          _emit('todo.updated', {
            'revision': 1,
            'todos': [
              for (var index = 0; index < 7; index++)
                {
                  'id': 'offline-task-$index',
                  'content': 'Inspect synthetic section $index',
                  'status': index < 3 ? 'completed' : 'pending',
                },
            ],
          });
          await next.refreshSubagents(_chat!);
          _emit('tool.complete', {
            'tool_id': 'offline-read',
            'name': 'read_file',
            'args': {'path': 'synthetic.md'},
            'result': '## Synthetic receipt\n\nExact offline tool result.',
            'duration_s': .2,
          });
          _emit('reasoning.available', {
            'text':
                'Check the **synthetic sections** before writing the answer.',
          });
        }
        _emit('message.delta', {'text': streamingReplayInitial()});
        await _awaitRendered(streamingReplayInitial());
      }
      _prepared = true;
      return {...ready(), 'preparing': false};
    } finally {
      _preparing = false;
      _abort = null;
    }
  }

  void _retireAfterDetachedFrame(ProfileWorkspaceController retired) {
    if (!_pendingRetiredControllers.add(retired)) return;
    unawaited(_disposeRetiredControllerAfterFrame(retired));
  }

  Future<void> _disposeRetiredControllerAfterFrame(
    ProfileWorkspaceController retired,
  ) async {
    await WidgetsBinding.instance.endOfFrame;
    _disposeRetiredController(retired);
  }

  void _disposeRetiredController(ProfileWorkspaceController retired) {
    if (_pendingRetiredControllers.remove(retired)) retired.dispose();
  }

  Map<String, Object?> startProbe() {
    if (!_prepared || _canceled || _running || _preparing || _probing) {
      throw StateError('Prepare an idle profile before starting the probe');
    }
    final owner = controller;
    final chat = _chat;
    final view = View.of(context);
    if (owner == null ||
        chat == null ||
        _idleHistoryCount == null ||
        !identical(owner.current?.chat, chat) ||
        chat.runtime.blocksTurnAdmission ||
        chat.reading.streaming.isNotEmpty ||
        chat.composer.observation.displayedText.isNotEmpty ||
        !(_composer?.widget.focusNode.hasFocus ?? false) ||
        view.viewInsets.bottom <= 0 ||
        !_idleRendererReady()) {
      throw StateError(
        'Idle profile, empty focused composer and keyboard required',
      );
    }
    CompletionDiagnostics.reset();
    _frames.clear();
    _probeNotifications = 0;
    _probeOwner = owner;
    owner.addListener(_countProbeNotification);
    _probeWatch = Stopwatch()..start();
    _probeGeometry = (
      view.physicalSize,
      view.viewInsets,
      view.devicePixelRatio,
      _textScaleAt14(),
    );
    _probeFocusAtStart = _composer!.widget.focusNode.hasFocus;
    _collecting = true;
    _probing = true;
    return {'started': true};
  }

  Future<Map<String, Object?>> stopProbe() async {
    if (!_probing) throw StateError('Start the probe before stopping it');
    try {
      await _endFrame();
      await _wait(const Duration(milliseconds: 150));
      final elapsedUs = _probeWatch?.elapsedMicroseconds ?? 0;
      _collecting = false;
      if (!mounted) throw StateError('Replay unmounted');
      final chat = _chat!;
      final view = View.of(context);
      final draft = chat.composer.observation.displayedText;
      final currentGeometry = (
        view.physicalSize,
        view.viewInsets,
        view.devicePixelRatio,
        _textScaleAt14(),
      );
      final expected = 'test ' * 40;
      final diagnostic = CompletionDiagnostics.snapshot();
      final totals = diagnostic['totals'] as Map<String, dynamic>? ?? const {};
      final transcriptBuilds =
          (totals['transcript.build_setup_sync']
                  as Map<String, dynamic>?)?['count']
              as int? ??
          0;
      final groupSyncs =
          (totals['transcript.group_sync'] as Map<String, dynamic>?)?['count']
              as int? ??
          0;
      final frames = _frames
          .map(
            (frame) => {
              'buildUs': frame.buildDuration.inMicroseconds,
              'rasterUs': frame.rasterDuration.inMicroseconds,
              'buildStartUs': frame.timestampInMicroseconds(
                FramePhase.buildStart,
              ),
            },
          )
          .toList();
      return {
        'historyRows': _idleHistoryCount!,
        'elapsedUs': elapsedUs,
        'workspaceNotifications': _probeNotifications,
        'draftCharacters': draft.length,
        'expectedDraftVerified': draft.toLowerCase() == expected,
        'keyboardHeightPx': view.viewInsets.bottom,
        'keyboardHeightStartPx': _probeGeometry?.$2.bottom ?? 0,
        'physicalWidthPx': view.physicalSize.width,
        'physicalHeightPx': view.physicalSize.height,
        'devicePixelRatio': view.devicePixelRatio,
        'textScaleAt14': _textScaleAt14(),
        'focused': _probeFocusAtStart && _composer!.widget.focusNode.hasFocus,
        'geometryStable': _probeGeometry == currentGeometry,
        'settled':
            !chat.runtime.blocksTurnAdmission && chat.reading.streaming.isEmpty,
        'renderReady': _idleRendererReady(),
        'diagnosticsEnabled': diagnostic['enabled'] == true,
        'transcript.build_setup_sync': transcriptBuilds,
        'transcript.group_sync': groupSyncs,
        'frames': frames,
      };
    } finally {
      _prepared = false;
      _clearProbe();
    }
  }

  bool _idleRendererReady() {
    final latestRow = 'Offline synthetic history row $_idleHistoryCount.';
    final elements = _walk(context as Element).toList();
    final latestMessage = elements.any(
      (element) =>
          element.widget is MarkdownMessageContent &&
          !(element.widget as MarkdownMessageContent).streaming &&
          (element.widget as MarkdownMessageContent).data == latestRow,
    );
    return latestMessage &&
        elements.whereType<RenderObjectElement>().any((element) {
          final render = element.renderObject;
          return render is RenderParagraph &&
                  render.hasSize &&
                  render.text.toPlainText().contains(latestRow) ||
              render is RenderEditable &&
                  render.hasSize &&
                  (render.text?.toPlainText().contains(latestRow) ?? false);
        });
  }

  void _clearProbe() {
    _collecting = false;
    _probing = false;
    _probeOwner?.removeListener(_countProbeNotification);
    _probeOwner = null;
    _probeWatch?.stop();
    _probeWatch = null;
    _probeGeometry = null;
  }

  Future<Map<String, Object?>> replay({
    String label = '',
    bool keyboardOpen = true,
  }) async {
    if (!_prepared ||
        _canceled ||
        _running ||
        _preparing ||
        _probing ||
        _idleHistoryCount != null) {
      throw StateError('Prepare before replay');
    }
    _running = true;
    _prepared = false;
    _abort = Completer<void>();
    try {
      _requireMounted();
      final owner = controller;
      final chat = _chat;
      if (owner == null ||
          chat == null ||
          !owner.initialized ||
          !identical(owner.current?.chat, chat) ||
          !chat.runtime.blocksTurnAdmission ||
          chat.reading.streaming != streamingReplayInitial() ||
          !_rendered(streamingReplayInitial())) {
        throw StateError(
          'Prepared source or selected chat changed; prepare again '
          '(execution=${chat?.runtime.execution.name}, '
          'source=${chat?.reading.streaming.length}, '
          'selected=${identical(owner?.current?.chat, chat)}, '
          'render=${renderedReadiness(streamingReplayInitial())})',
        );
      }
      final view = View.of(context);
      if ((view.viewInsets.bottom > 0) != keyboardOpen ||
          (keyboardOpen && !_composer!.widget.focusNode.hasFocus)) {
        throw StateError('Settle the requested keyboard state before replay');
      }
      final geometry = (
        view.physicalSize,
        view.viewInsets,
        view.devicePixelRatio,
        _textScaleAt14(),
      );
      final keyboardStart = view.viewInsets.bottom;
      final focus = _composer!.widget.focusNode;
      var geometryStable = true;
      var focusHeld = focus.hasFocus;
      final run = ++_run;
      CompletionDiagnostics.reset();
      _frames.clear();
      _collecting = true;
      final startUs = developer.Timeline.now;
      final startEpochUs = DateTime.now().microsecondsSinceEpoch;
      final watch = Stopwatch()..start();
      final growth = streamingReplayGrowth();
      final achieved = <int>[];
      var consumed = 0;
      developer.Timeline.instantSync(
        'WingWorkspaceReplayStart',
        arguments: {'run': run},
      );
      for (var index = 0; index < workspaceReplayDeltaCount; index++) {
        final deadline = (index + 1) * workspaceReplayIntervalUs;
        await _wait(
          Duration(
            microseconds: math.max(0, deadline - watch.elapsedMicroseconds),
          ),
        );
        final end = ((index + 1) * growth.length / workspaceReplayDeltaCount)
            .floor();
        _emit('message.delta', {'text': growth.substring(consumed, end)});
        consumed = end;
        achieved.add(developer.Timeline.now);
        geometryStable =
            geometryStable &&
            geometry ==
                (
                  view.physicalSize,
                  view.viewInsets,
                  view.devicePixelRatio,
                  _textScaleAt14(),
                );
        focusHeld = focusHeld && focus.hasFocus;
      }
      final streamEndUs = developer.Timeline.now;
      final finalSource = streamingReplayInitial() + growth;
      _completeSource(finalSource);
      await _wait(const Duration(milliseconds: 500));
      final endUs = developer.Timeline.now;
      geometryStable =
          geometryStable &&
          geometry ==
              (
                view.physicalSize,
                view.viewInsets,
                view.devicePixelRatio,
                _textScaleAt14(),
              );
      focusHeld = focusHeld && focus.hasFocus;
      developer.Timeline.instantSync(
        'WingWorkspaceReplayEnd',
        arguments: {'run': run},
      );
      await _wait(const Duration(milliseconds: 1500));
      _collecting = false;
      final frames = _frames
          .where((frame) {
            final start = frame.timestampInMicroseconds(FramePhase.buildStart);
            return start >= startUs && start < endUs;
          })
          .map(
            (frame) => {
              'startUs': frame.timestampInMicroseconds(FramePhase.buildStart),
              'buildEndUs': frame.timestampInMicroseconds(
                FramePhase.buildFinish,
              ),
              'rasterStartUs': frame.timestampInMicroseconds(
                FramePhase.rasterStart,
              ),
              'rasterEndUs': frame.timestampInMicroseconds(
                FramePhase.rasterFinish,
              ),
              'rasterFinishEpochUs': frame.timestampInMicroseconds(
                FramePhase.rasterFinishWallTime,
              ),
              'buildUs': frame.buildDuration.inMicroseconds,
              'rasterUs': frame.rasterDuration.inMicroseconds,
            },
          )
          .toList();
      await _awaitRendered(finalSource);
      final exactSource = _chat!.reading.messages.any(
        (row) => row['role'] == 'assistant' && row['content'] == finalSource,
      );
      return {
        'label': label,
        'run': run,
        'startUs': startUs,
        'startEpochUs': startEpochUs,
        'streamEndUs': streamEndUs,
        'endUs': endUs,
        'deltaCount': achieved.length,
        'deltaIntervalUs': workspaceReplayIntervalUs,
        'deltaAchievedUs': achieved,
        'sourceCodeUnits': finalSource.length,
        'source': finalSource,
        'initialSource': streamingReplayInitial(),
        'draft': _chat!.composer.observation.displayedText,
        'exactFinalSource': exactSource,
        'finalRendererReady': _rendered(finalSource),
        'rendererMetrics': renderedReadiness(finalSource),
        'completed': !_chat!.runtime.blocksTurnAdmission,
        'geometryStable': geometryStable,
        'focusHeld': focusHeld,
        'keyboardStartPx': keyboardStart,
        'keyboardEndPx': view.viewInsets.bottom,
        'keyboardOpen': keyboardOpen,
        'displayRefreshHz': view.display.refreshRate,
        'physicalWidthPx': view.physicalSize.width,
        'physicalHeightPx': view.physicalSize.height,
        'devicePixelRatio': view.devicePixelRatio,
        'textScaleAt14': _textScaleAt14(),
        'nativeDraftStorage': false,
        'completionDiagnostics': CompletionDiagnostics.snapshot(),
        'valid':
            exactSource &&
            !_chat!.runtime.blocksTurnAdmission &&
            _rendered(finalSource) &&
            geometryStable &&
            (!keyboardOpen || focusHeld) &&
            (keyboardStart > 0) == keyboardOpen &&
            frames.isNotEmpty,
        'frames': frames,
      };
    } finally {
      _collecting = false;
      _running = false;
      _abort = null;
    }
  }

  @override
  Widget build(BuildContext context) =>
      controller == null || !controller!.initialized
      ? const Scaffold(body: Center(child: Text('Prepare offline replay')))
      : ProfileWorkspaceScreen(
          key: ObjectKey(controller),
          controller: controller!,
          createBotsSession: () => BotsSession((_) async => const []),
        );

  @override
  void dispose() {
    _clearProbe();
    _canceled = true;
    if (_abort case final abort? when !abort.isCompleted) {
      abort.complete();
    }
    WidgetsBinding.instance.removeObserver(this);
    for (final retired in _pendingRetiredControllers.toList()) {
      _disposeRetiredController(retired);
    }
    WidgetsBinding.instance.removeTimingsCallback(_timings);
    controller?.dispose();
    _appPreferences?.dispose();
    super.dispose();
  }
}
