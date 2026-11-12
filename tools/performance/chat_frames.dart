// Benchmark entry point only. Ordinary builds do not register these observers.
// flutter build apk --profile --dart-define=WING_PERF_INSTRUMENTATION=true -t tools/performance/chat_frames.dart
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:wing/core/services/performance_instrumentation.dart';
import 'package:flutter/material.dart';
import 'package:wing/core/screens/profile_workspace_browser.dart';
import 'package:wing/core/widgets/studio_error.dart';
import 'package:wing/main.dart' as app;

Iterable<Element> _walk(Element element) sync* {
  if (element.widget case Offstage(offstage: true)) return;
  yield element;
  final children = <Element>[];
  element.visitChildren(children.add);
  for (final child in children) {
    yield* _walk(child);
  }
}

List<Element> _browserElements() {
  final root = WidgetsBinding.instance.rootElement;
  if (root == null) throw StateError('App has not mounted');
  final browser = _walk(
    root,
  ).where((e) => e.widget is ProfileWorkspaceBrowser).single;
  return _walk(browser).toList();
}

Map<String, Object?> _snapshot() {
  final elements = _browserElements();
  final browser = elements.first.widget as ProfileWorkspaceBrowser;
  final observation =
      (elements.first as StatefulElement).state as BrowserWorkspaceObservation;
  final workspace = observation.workspace;
  final errors = elements.map((e) => e.widget).whereType<StudioError>();
  // Never export chat text, profile names, connection addresses or credentials.
  return {
    'initialized': workspace.initialized,
    'profiles': workspace.profiles.length,
    'connection': browser.connectionStatus.description,
    'controllerError': workspace.error != null,
    'loading': elements.any((e) => e.widget is LinearProgressIndicator),
    'visibleErrors': errors.length,
    'profileLoadingErrors': errors
        .where((e) => e.message.startsWith('Could not finish loading '))
        .length,
  };
}

void main() {
  if (!PerformanceInstrumentation.enabled) {
    throw StateError(
      'Build with --dart-define=WING_PERF_INSTRUMENTATION=true.',
    );
  }
  if (!kProfileMode) {
    throw StateError('Measure frame performance with an AOT profile build.');
  }
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint(
    '[WingPerf] profile source='
    '${const String.fromEnvironment('WING_REVIEW_REVISION', defaultValue: 'working-copy')}',
  );
  WidgetsBinding.instance.addTimingsCallback((frames) {
    debugPrint(
      '[WingPerf] frames '
      'buildUs=${frames.map((f) => f.buildDuration.inMicroseconds).join(',')} '
      'rasterUs=${frames.map((f) => f.rasterDuration.inMicroseconds).join(',')}',
    );
  });
  for (final action in ['snapshot', 'top', 'refresh']) {
    developer.registerExtension('ext.wingPerf.$action', (_, _) async {
      try {
        final watch = Stopwatch()..start();
        if (action != 'snapshot') {
          final elements = _browserElements();
          final states = elements.whereType<StatefulElement>().map(
            (e) => e.state,
          );
          final list = states
              .whereType<ScrollableState>()
              .where((s) => s.widget.axisDirection == AxisDirection.down)
              .single;
          list.position.jumpTo(0);
          if (action == 'refresh') {
            await states.whereType<RefreshIndicatorState>().single.show();
          }
          WidgetsBinding.instance.scheduleFrame();
          await WidgetsBinding.instance.endOfFrame;
        }
        return developer.ServiceExtensionResponse.result(
          jsonEncode({..._snapshot(), 'elapsedMs': watch.elapsedMilliseconds}),
        );
      } catch (_) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          'Open the Chats list before running this measurement.',
        );
      }
    });
  }
  app.main();
}
