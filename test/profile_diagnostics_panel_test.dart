import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/administration_overview.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/widgets/profile_diagnostics_panel.dart';
import 'package:wing/core/services/profile_diagnostics_controller.dart';
import 'package:wing/core/screens/administration/admin_widgets.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_error.dart';

class _DiagnosticsHost {
  final reads = <(String, Map<String, String>)>[];
  final calls = <(String, Map<String, dynamic>)>[];
  Future<Map<String, dynamic>> Function(String, Map<String, String>)? onRead;
  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)? onCall;

  ProfileWorkspaceData workspace(String profile) {
    final scope = WorkspaceScope(
      connectionId: 'connection',
      profileName: profile,
    );
    return ProfileWorkspaceData(
      ProfileGateway(
        scope: scope,
        discover: () async => const ProfileDiscovery(
          profiles: [],
          currentName: null,
          activeName: null,
        ),
        get: (endpoint, query) {
          reads.add((endpoint, query));
          return onRead?.call(endpoint, query) ??
              Future.value(<String, dynamic>{});
        },
        rpc: (method, params) {
          calls.add((method, params));
          return onCall?.call(method, params) ??
              Future.value(
                method == 'setup.status'
                    ? <String, dynamic>{'provider_configured': true}
                    : <String, dynamic>{
                        // Stock native gateway validates the request's profile
                        // and returns readiness without a profile echo.
                        'ok': true,
                        'model': 'gpt-5.6-sol',
                        'provider': 'openai-codex',
                      },
              );
        },
      ),
    );
  }
}

Widget _app(
  ProfileWorkspaceData workspace, {
  VoidCallback? onManage,
  VoidCallback? onProvider,
  AdministrationObservation? observation,
  Brightness brightness = Brightness.light,
  ProfileDiagnosticsController? controller,
  double textScale = 1,
}) {
  final diagnostics =
      controller ?? ProfileDiagnosticsController(gateway: workspace.gateway);
  if (controller == null) addTearDown(diagnostics.dispose);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: wingTheme(brightness),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: RepaintBoundary(key: const ValueKey('capture'), child: child!),
    ),
    home: AdminPage(
      title: 'Hermes health',
      scope: 'Claw / work',
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              const Expanded(child: Text('Profile')),
              ListenableBuilder(
                listenable: diagnostics,
                builder: (context, _) => IconButton(
                  tooltip: 'Refresh profile status',
                  onPressed: diagnostics.check,
                  icon: const Icon(Icons.refresh),
                ),
              ),
            ],
          ),
          AdminGroup(
            children: [
              ProfileModelAccessRow(
                controller: diagnostics,
                modelObservation: ModelAccessObservation.fromObservation(
                  observation ??
                      AdministrationObservation(
                        data: {
                          'model': 'gpt-5.6-sol',
                          'provider': 'openai-codex',
                        },
                      ),
                ),
                refreshing: false,
                onRetry: diagnostics.check,
                onManageConnections: onManage ?? () {},
                onFixAccess: onProvider ?? () {},
              ),
            ],
          ),
          Builder(
            builder: (context) => Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
              child: Text(
                'Model access checks credentials. Replies and quota aren’t tested.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets(
    'native readiness without a profile echo shows healthy passive access',
    (tester) async {
      final host = _DiagnosticsHost();
      await tester.pumpWidget(_app(host.workspace('work')));
      expect(host.reads, isEmpty);
      expect(host.calls, isEmpty);
      await tester.tap(find.byTooltip('Refresh profile status'));
      await tester.pumpAndSettle();
      expect(host.reads, isEmpty);
      expect(host.calls, hasLength(1));
      expect(host.calls.single.$1, 'setup.runtime_check');
      expect(host.calls.single.$2, {'profile': 'work'});
      expect(find.text('Access is set up'), findsOneWidget);
      expect(find.byType(Card), findsOneWidget);
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      expect(find.text('Fix access'), findsNothing);
      expect(find.text('Change model'), findsNothing);
      expect(find.text('Manage provider access'), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      await tester.tap(find.text('Model access'));
      await tester.pumpAndSettle();
      expect(find.text('Hermes health'), findsOneWidget);
      expect(host.calls, hasLength(1));
    },
  );

  testWidgets('does not mistake a failed check for missing credentials', (
    tester,
  ) async {
    final host = _DiagnosticsHost()
      ..onCall = (_, _) async => {
        'ok': false,
        'error': 'secret backend detail',
      };
    await tester.pumpWidget(_app(host.workspace('work')));
    await tester.tap(find.byTooltip('Refresh profile status'));
    await tester.pumpAndSettle();
    expect(find.text('Provider check failed'), findsOneWidget);
    expect(find.textContaining('secret backend detail'), findsNothing);
    expect(find.text('Credentials missing'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Fix access'), findsOneWidget);
  });

  testWidgets(
    'missing credentials leads to provider access; retry replaces failure',
    (tester) async {
      final host = _DiagnosticsHost()
        ..onCall = (_, _) async => {
          'ok': false,
          'error': 'No usable credentials found for openai-codex.',
        };
      var managed = false;
      await tester.pumpWidget(
        _app(host.workspace('work'), onProvider: () => managed = true),
      );
      await tester.tap(find.byTooltip('Refresh profile status'));
      await tester.pumpAndSettle();
      expect(find.text('Credentials missing'), findsOneWidget);
      await tester.tap(find.text('Fix access'));
      expect(managed, isTrue);
      host.onCall = (_, _) async => {
        'ok': true,
        'profile': 'work',
        'model': 'gpt-5.6-sol',
        'provider': 'openai-codex',
      };
      await tester.tap(find.byTooltip('Refresh profile status'));
      await tester.pumpAndSettle();
      expect(find.text('Access is set up'), findsOneWidget);
      expect(find.text('Credentials missing'), findsNothing);
    },
  );

  testWidgets(
    'connection rejection has its own recovery without leaking response',
    (tester) async {
      final host = _DiagnosticsHost()
        ..onCall = (_, _) async =>
            throw const DashboardHttpException(401, 'sensitive/path');
      var managed = false;
      await tester.pumpWidget(
        _app(host.workspace('work'), onManage: () => managed = true),
      );
      await tester.tap(find.byTooltip('Refresh profile status'));
      await tester.pumpAndSettle();
      expect(find.text('Server access denied'), findsOneWidget);
      expect(find.textContaining('sensitive/path'), findsNothing);
      await tester.tap(find.text('Review connection'));
      expect(managed, isTrue);
      expect(find.text('Fix access'), findsNothing);
    },
  );

  testWidgets(
    'unavailable, malformed and wrong-profile results cannot turn green',
    (tester) async {
      final host = _DiagnosticsHost();
      final workspace = host.workspace('work');
      final controller = ProfileDiagnosticsController(
        gateway: workspace.gateway,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(_app(workspace, controller: controller));
      host.onCall = (_, _) async => throw TimeoutException('secret');
      final checking = controller.check();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 2));
      await checking;
      await tester.pumpAndSettle();
      expect(find.text('Check incomplete'), findsOneWidget);
      expect(find.textContaining('Last attempt'), findsNothing);
      for (final response in [
        {},
        {'ok': true},
        {'ok': true, 'model': 'gpt-5.6-sol'},
        {'ok': true, 'provider': 'openai-codex'},
        {'ok': true, 'profile': 'another'},
        {
          'ok': true,
          'profile': 'another',
          'model': 'gpt-5.6-sol',
          'provider': 'openai-codex',
        },
        {'ok': false, 'profile': 'another'},
      ]) {
        host.onCall = (_, _) async => Map<String, dynamic>.from(response);
        await controller.check();
        await tester.pumpAndSettle();
        expect(find.text('Check incomplete'), findsOneWidget);
        expect(find.text('Access is set up'), findsNothing);
      }
    },
  );

  testWidgets(
    'incomplete check offers Retry and clears the action after success',
    (tester) async {
      final host = _DiagnosticsHost()..onCall = (_, _) async => {};
      await tester.pumpWidget(_app(host.workspace('work')));
      await tester.tap(find.byTooltip('Refresh profile status'));
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Fix access'), findsNothing);
      final retry = Completer<Map<String, dynamic>>();
      host.onCall = (_, _) => retry.future;
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(find.text('Checking access…'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      retry.complete({
        'ok': true,
        'model': 'gpt-5.6-sol',
        'provider': 'openai-codex',
      });
      await tester.pumpAndSettle();
      expect(find.text('Access is set up'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(host.calls, hasLength(2));
    },
  );

  testWidgets('late results do not cross profile scope', (tester) async {
    final dashboard = Completer<Map<String, dynamic>>();
    final setup = Completer<Map<String, dynamic>>();
    final runtime = Completer<Map<String, dynamic>>();
    final oldHost = _DiagnosticsHost();
    oldHost.onRead = (_, _) => dashboard.future;
    oldHost.onCall = (method, _) =>
        method == 'setup.status' ? setup.future : runtime.future;
    final oldWorkspace = oldHost.workspace('old');
    final controller = ProfileDiagnosticsController(
      gateway: oldWorkspace.gateway,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(oldWorkspace, controller: controller));
    await tester.tap(find.byTooltip('Refresh profile status'));
    await tester.pump();

    final newHost = _DiagnosticsHost();
    final newWorkspace = newHost.workspace('new');
    controller.updateGateway(newWorkspace.gateway);
    await tester.pumpWidget(_app(newWorkspace, controller: controller));
    dashboard.complete({});
    setup.complete({'provider_configured': true});
    runtime.complete({'ok': true});
    await tester.pump();

    expect(find.text('Credentials not checked'), findsOneWidget);
    expect(find.text('Authenticated dashboard API responded.'), findsNothing);
  });

  testWidgets('disposed controller ignores late results', (tester) async {
    final pending = Completer<Map<String, dynamic>>();
    final host = _DiagnosticsHost();
    host.onRead = (_, _) => pending.future;
    host.onCall = (_, _) => pending.future;
    final workspace = host.workspace('work');
    final controller = ProfileDiagnosticsController(gateway: workspace.gateway);
    await tester.pumpWidget(_app(workspace, controller: controller));
    await tester.tap(find.byTooltip('Refresh profile status'));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    controller.dispose();

    pending.complete({
      'profile': 'work',
      'ok': true,
      'model': 'gpt-5.6-sol',
      'provider': 'openai-codex',
    });
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('completed checks survive reopening without additional calls', (
    tester,
  ) async {
    final host = _DiagnosticsHost();
    final workspace = host.workspace('work');
    final controller = ProfileDiagnosticsController(gateway: workspace.gateway);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(workspace, controller: controller));
    await tester.tap(find.byTooltip('Refresh profile status'));
    await tester.pumpAndSettle();
    final checkedAt = controller.healthObservation.finding!.checkedAt;

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    controller.updateGateway(workspace.gateway);
    await tester.pumpWidget(_app(workspace, controller: controller));

    expect(find.text('Access is set up'), findsOneWidget);
    expect(controller.healthObservation.finding!.checkedAt, checkedAt);
    expect(find.textContaining(RegExp(r'^Checked [0-9]')), findsNothing);
    expect(host.reads, isEmpty);
    expect(host.calls, hasLength(1));
  });

  testWidgets('pending checks complete while the panel is closed', (
    tester,
  ) async {
    final pending = Completer<Map<String, dynamic>>();
    final host = _DiagnosticsHost();
    host.onRead = (_, _) => pending.future;
    host.onCall = (_, _) => pending.future;
    final workspace = host.workspace('work');
    final controller = ProfileDiagnosticsController(gateway: workspace.gateway);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(workspace, controller: controller));
    await tester.tap(find.byTooltip('Refresh profile status'));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    pending.complete({
      'profile': 'work',
      'ok': true,
      'model': 'gpt-5.6-sol',
      'provider': 'openai-codex',
    });
    await tester.pump();
    await tester.pumpWidget(_app(workspace, controller: controller));

    expect(find.text('Access is set up'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^Checked [0-9]')), findsNothing);
    expect(controller.healthObservation.finding!.checkedAt, isNotNull);
    expect(host.reads, isEmpty);
    expect(host.calls, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'replaced gateway invalidates pending results for the same profile',
    (tester) async {
      final pending = Completer<Map<String, dynamic>>();
      final oldHost = _DiagnosticsHost();
      oldHost.onRead = (_, _) => pending.future;
      oldHost.onCall = (_, _) => pending.future;
      final oldWorkspace = oldHost.workspace('work');
      final controller = ProfileDiagnosticsController(
        gateway: oldWorkspace.gateway,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(_app(oldWorkspace, controller: controller));
      await tester.tap(find.byTooltip('Refresh profile status'));
      await tester.pump();
      final newHost = _DiagnosticsHost();
      final newWorkspace = newHost.workspace('work');
      controller.updateGateway(newWorkspace.gateway);
      await tester.pumpWidget(_app(newWorkspace, controller: controller));
      pending.complete({
        'profile': 'work',
        'ok': true,
        'model': 'gpt-5.6-sol',
        'provider': 'openai-codex',
      });
      await tester.pump();

      expect(find.text('Credentials not checked'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^Checked [0-9]')), findsNothing);
      expect(newHost.reads, isEmpty);
      expect(newHost.calls, isEmpty);
      await tester.tap(find.byTooltip('Refresh profile status'));
      await tester.pumpAndSettle();
      expect(find.text('Access is set up'), findsOneWidget);
    },
  );

  test(
    'selection changes discard retained and pending credential checks',
    () async {
      final host = _DiagnosticsHost();
      final controller = ProfileDiagnosticsController(
        gateway: host.workspace('work').gateway,
      );
      addTearDown(controller.dispose);
      controller.updateModel({
        'model': 'gpt-5.6-sol',
        'provider': 'openai-codex',
      });
      await controller.check();
      expect(controller.healthObservation.finding?.detail, 'Access is set up');
      controller.updateModel({
        'model': 'gpt-5.6-sol',
        'provider': 'openai-codex',
      });
      expect(controller.healthObservation.finding?.detail, 'Access is set up');
      controller.updateModel({'model': 'gpt-5.6-sol', 'provider': 'openai'});
      expect(controller.healthObservation.finding, isNull);
      final pending = Completer<Map<String, dynamic>>();
      host.onCall = (_, _) => pending.future;
      final check = controller.check();
      controller.updateModel({'model': 'another-model', 'provider': 'openai'});
      pending.complete({
        'ok': true,
        'profile': 'work',
        'model': 'gpt-5.6-sol',
        'provider': 'openai',
      });
      await check;
      expect(controller.healthObservation.finding, isNull);
    },
  );

  testWidgets('resolved route cannot validate a different selected route', (
    tester,
  ) async {
    final host = _DiagnosticsHost()
      ..onCall = (_, _) async => {
        'ok': true,
        'profile': 'work',
        'model': 'claude-sonnet-4-6',
        'provider': 'anthropic',
      };
    final workspace = host.workspace('work');
    final controller = ProfileDiagnosticsController(gateway: workspace.gateway);
    addTearDown(controller.dispose);
    controller.updateModel({
      'model': 'gpt-5.6-sol',
      'provider': 'openai-codex',
    });
    await controller.check();
    await tester.pumpWidget(_app(workspace, controller: controller));
    expect(find.text('Access is set up'), findsNothing);
    expect(
      find.textContaining(
        'Hermes resolved claude-sonnet-4-6 · anthropic instead.',
      ),
      findsOneWidget,
    );
    expect(find.text('Selected model access unconfirmed'), findsOneWidget);
    host.onCall = (_, _) async => {'ok': true, 'profile': 'work'};
    await controller.check();
    await tester.pump();
    expect(find.text('Check incomplete'), findsOneWidget);
  });

  const capture = bool.fromEnvironment('CAPTURE_PROVIDER_ACCESS');
  setUpAll(() async {
    if (!capture) return;
    for (final entry in {
      'Roboto': 'roboto-regular.ttf',
      'MaterialIcons': 'materialicons-regular.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(
              '/tmp/wing-header-fonts/${entry.value}',
            ).readAsBytes().then((b) => b.buffer.asByteData()),
          ))
          .load();
    }
  });
  Future<void> snapshot(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/model-access-row-review/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final state in [
        'initial',
        'model-loading',
        'model-unavailable',
        'model-malformed',
        'model-stale',
        'checking',
        'ready',
        'different',
        'missing',
        'failed',
        'offline',
        'incomplete',
      ]) {
        testWidgets('$state ${brightness.name} at $scale', (tester) async {
          tester.view.physicalSize = Size(scale == 2 ? 320 : 412, 832);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final host = _DiagnosticsHost();
          final pending = Completer<Map<String, dynamic>>();
          host.onCall = (_, _) async => switch (state) {
            'checking' => pending.future,
            'different' => {
              'ok': true,
              'profile': 'work',
              'model': 'claude-sonnet-4-6',
              'provider': 'anthropic',
            },
            'missing' => {
              'ok': false,
              'error': 'No Hermes provider is configured.',
            },
            'failed' => {'ok': false, 'error': 'other'},
            'offline' => throw TimeoutException('offline'),
            'incomplete' => {},
            _ => {
              'ok': true,
              'profile': 'work',
              'model': 'gpt-5.6-sol',
              'provider': 'openai-codex',
            },
          };
          final workspace = host.workspace('work');
          final controller = ProfileDiagnosticsController(
            gateway: workspace.gateway,
          );
          addTearDown(controller.dispose);
          controller.updateModel({
            'model': 'gpt-5.6-sol',
            'provider': 'openai-codex',
          });
          if (state != 'initial' && !state.startsWith('model-')) {
            final check = controller.check();
            if (state == 'offline') {
              await tester.pump();
              await tester.pump(const Duration(seconds: 1));
              await tester.pump(const Duration(seconds: 2));
            }
            if (state != 'checking') await check;
          }
          await tester.pumpWidget(
            _app(
              workspace,
              controller: controller,
              textScale: scale,
              brightness: brightness,
              observation: switch (state) {
                'model-loading' => AdministrationObservation(loading: true),
                'model-unavailable' => AdministrationObservation(
                  error: 'Offline',
                ),
                'model-malformed' => AdministrationObservation(
                  data: {'model': 17},
                ),
                'model-stale' => AdministrationObservation(
                  data: {'model': 'gpt-5.6-sol', 'provider': 'openai-codex'},
                  error: 'Offline',
                ),
                _ => null,
              },
            ),
          );
          await tester.pump();
          final name = '$state-${brightness.name}-$scale';
          final row = find.byType(ProfileModelAccessRow);
          final icon = tester.widget<Icon>(
            find.descendant(of: row, matching: find.byType(Icon)).first,
          );
          final tokens = WingTokens.of(tester.element(row));
          expect(icon.color, switch (state) {
            'ready' => tokens.success,
            'different' => tokens.warning,
            'missing' || 'failed' => tokens.danger,
            _ => Theme.of(tester.element(row)).colorScheme.onSurfaceVariant,
          });
          expect(
            find.text(switch (state) {
              'checking' => 'Checking access…',
              'ready' => 'Access is set up',
              'different' => 'Selected model access unconfirmed',
              'missing' => 'Credentials missing',
              'failed' => 'Provider check failed',
              'offline' || 'incomplete' => 'Check incomplete',
              _ => 'Credentials not checked',
            }),
            findsOneWidget,
          );
          if (state == 'model-loading') {
            expect(find.text('Loading model…'), findsOneWidget);
          } else if (const {
            'model-unavailable',
            'model-malformed',
            'model-stale',
          }.contains(state)) {
            expect(
              find.descendant(
                of: find.byType(StudioError),
                matching: find.text('Could not read the selected model.'),
              ),
              findsOneWidget,
            );
            expect(
              find.text('Showing the last known model.'),
              state == 'model-stale' ? findsOneWidget : findsNothing,
            );
          }
          await snapshot(tester, name);
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(
            find.byType(TextButton).evaluate().isNotEmpty
                ? find.byType(TextButton).first
                : find.byType(ProfileModelAccessRow),
          );
          await tester.pump();
          await snapshot(tester, '$name-actions');
          expect(tester.takeException(), isNull);
          if (state == 'checking') {
            expect(find.byType(TextButton), findsNothing);
            await controller.check();
            expect(host.calls, hasLength(1));
            pending.complete({
              'ok': true,
              'profile': 'work',
              'model': 'gpt-5.6-sol',
              'provider': 'openai-codex',
            });
            await tester.pumpAndSettle();
          }
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }
}
