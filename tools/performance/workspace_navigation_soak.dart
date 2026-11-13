import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/chat_runtime.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/performance_instrumentation.dart';
import 'package:wing/core/theme/wing_theme.dart';

import '../../test/workspace_retention_test.dart' show RetentionFixture;

const _chatsPerRound = 20;
const _maxIncreasingRounds = 20;

void main() {
  if (!kProfileMode || !PerformanceInstrumentation.enabled) {
    throw StateError(
      'Build a profile APK with WING_PERF_INSTRUMENTATION=true.',
    );
  }
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      theme: wingTheme(Brightness.light),
      home: const WorkspaceNavigationSoak(),
    ),
  );
}

class _CountedRuntime extends ChatRuntime {
  _CountedRuntime(String runtimeId, this.onDispose)
    : super(runtimeId: runtimeId);

  final VoidCallback onDispose;
  var _disposeCounted = false;

  @override
  void dispose() {
    if (!_disposeCounted) {
      _disposeCounted = true;
      onDispose();
    }
    super.dispose();
  }
}

class WorkspaceNavigationSoak extends StatefulWidget {
  const WorkspaceNavigationSoak({super.key});

  @override
  State<WorkspaceNavigationSoak> createState() =>
      WorkspaceNavigationSoakState();
}

class WorkspaceNavigationSoakState extends State<WorkspaceNavigationSoak>
    with WidgetsBindingObserver {
  ProfileWorkspaceController? _owner;
  AppPreferences? _appPreferences;
  RetentionFixture? _fixture;
  Future<void>? _initializing;
  Completer<void>? _abort;
  var _runtimeCreated = 0;
  var _runtimeClosed = 0;
  var _increasingRound = 0;
  var _running = false;
  var _cancelled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializing = _initialize();
    if (PerformanceInstrumentation.enabled && kProfileMode) {
      developer.registerExtension('ext.wingNavigationSoak.ready', (_, _) async {
        try {
          await _initializing;
          return _response(ready());
        } catch (error) {
          return _error(error);
        }
      });
      developer.registerExtension('ext.wingNavigationSoak.round', (
        _,
        parameters,
      ) async {
        try {
          await _initializing;
          return _response(await round(parameters['mode']));
        } catch (error) {
          return _error(error);
        }
      });
    }
  }

  Future<void> _initialize() async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    _appPreferences = AppPreferences(preferences);
    final fixture = _fixture = RetentionFixture()..count = 200;
    _owner = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'qa-navigation-soak',
          label: 'Offline navigation soak',
          host: 'localhost',
          port: 1,
          dashboardPortOverride: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'qa-navigation-soak',
      preferences: preferences,
      appPreferences: _appPreferences!,
      gatewayFactory: fixture.gateway,
      runtimeFactory: (_, runtimeId) {
        _runtimeCreated++;
        return _CountedRuntime(runtimeId, () => _runtimeClosed++);
      },
    );
    await _owner!.initialize();
    if (mounted) setState(() {});
  }

  Map<String, Object?> ready() => {
    'ready': _owner?.initialized == true && !_cancelled,
    // ignore: invalid_use_of_visible_for_testing_member
    'retainedChatCount': _owner?.retainedChatCount ?? 0,
    'historyRowsPerChat': 50,
    'historyCodeUnitsPerChat': 50 * 1024,
  };

  Future<Map<String, Object?>> round(String? mode) async {
    if (mode != 'same' && mode != 'increasing') {
      throw ArgumentError.value(mode, 'mode', 'Expected same or increasing');
    }
    final owner = _owner;
    final fixture = _fixture;
    if (owner == null || fixture == null || !owner.initialized || _cancelled) {
      throw StateError('Navigation soak is not ready');
    }
    if (_running) throw StateError('A navigation round is already active');
    if (mode == 'increasing' && _increasingRound >= _maxIncreasingRounds) {
      throw StateError('Increasing mode is limited to 20 rounds');
    }
    _running = true;
    _abort = Completer<void>();
    fixture.calls.clear();
    fixture.reads.clear();
    final watch = Stopwatch()..start();
    var navigationCount = 0;
    try {
      final first = mode == 'same' ? 0 : _increasingRound * _chatsPerRound;
      if (mode == 'increasing') {
        _increasingRound++;
        fixture.count = first + _chatsPerRound < 200
            ? 200
            : first + _chatsPerRound;
      }
      for (var offset = 0; offset < _chatsPerRound; offset++) {
        _requireActive();
        final id = 'chat-${first + offset}';
        final chat = await owner.openSession(
          ProfileSessionKey(owner.current!.scope, id),
        );
        if (chat == null) throw StateError('Authored chat could not be opened');
        navigationCount++;
        await _frame();
        _requireActive();
        owner.showList();
        await _frame();
        owner.pruneSettledState();
        await Future<void>.delayed(Duration.zero);
      }
      watch.stop();
      final resource = owner.current!;
      final active = resource.chats.values
          .where((chat) => chat.runtime.blocksTurnAdmission)
          .length;
      final contentUnits = resource.chats.values.fold<int>(
        0,
        (sum, chat) =>
            sum +
            chat.reading.messages.fold<int>(
              0,
              (size, row) => size + (row['content'] as String).length,
            ),
      );
      return {
        'mode': mode,
        'round': mode == 'same' ? 0 : _increasingRound,
        'navigationCount': navigationCount,
        // ignore: invalid_use_of_visible_for_testing_member
        'retainedChatCount': owner.retainedChatCount,
        'retainedContentCodeUnits': contentUnits,
        'activeStateCount': active,
        'runtimeCreated': _runtimeCreated,
        'runtimeClosed': _runtimeClosed,
        'uiCurrentList': resource.chat == null,
        'elapsedUs': watch.elapsedMicroseconds,
        'fixtureCalls': fixture.calls.length,
        'fixtureReads': fixture.reads.length,
      };
    } finally {
      if (owner.current?.chat != null) owner.showList();
      owner.pruneSettledState();
      fixture.calls.clear();
      fixture.reads.clear();
      _running = false;
      _abort = null;
    }
  }

  void _requireActive() {
    if (!mounted ||
        _cancelled ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      throw StateError('Navigation soak was interrupted');
    }
  }

  Future<void> _frame() async {
    _requireActive();
    WidgetsBinding.instance.scheduleFrame();
    await Future.any([
      WidgetsBinding.instance.endOfFrame,
      _abort!.future.then((_) => throw StateError('Navigation soak canceled')),
    ]);
    _requireActive();
  }

  developer.ServiceExtensionResponse _error(Object error) =>
      developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        error.runtimeType.toString(),
      );

  developer.ServiceExtensionResponse _response(Map<String, Object?> value) =>
      developer.ServiceExtensionResponse.result(jsonEncode(value));

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    _cancelled = true;
    if (_abort case final abort? when !abort.isCompleted) abort.complete();
  }

  @override
  Widget build(BuildContext context) => _owner?.initialized == true
      ? ProfileWorkspaceScreen(controller: _owner!)
      : const Scaffold(body: Center(child: CircularProgressIndicator()));

  @override
  void dispose() {
    _cancelled = true;
    if (_abort case final abort? when !abort.isCompleted) abort.complete();
    WidgetsBinding.instance.removeObserver(this);
    _owner?.dispose();
    _appPreferences?.dispose();
    super.dispose();
  }
}
