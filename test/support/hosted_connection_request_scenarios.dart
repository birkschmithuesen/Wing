import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/hosted_connection_request_panel.dart';
import '../profile_connection_identity_test.dart' show identityTestConnection;
import 'canonical_gateway_fixture.dart';
import 'form_family_capture.dart';
import 'profile_browser_fixture.dart';

Map<String, dynamic> connectionRequest({
  String id = 'mail-request',
  int seq = 0,
  List<String>? suggested,
  List<Map<String, dynamic>>? targets,
}) => {
  'op_id': id,
  'seq': seq,
  'deadline_at': 1999999999,
  'timeout_seconds': 300,
  'tool_call_id': 'connect-1',
  if (suggested != null) 'display': {'suggested': suggested},
  'targets':
      targets ??
      (suggested != null
          ? []
          : [
              {
                'name': 'Gmail',
                'kind': 'connector',
                'action': 'connect',
                'state': 'initiated',
                'alias': 'work',
                'connect_url': 'https://accounts.example.test/authorize',
              },
            ]),
};

const mcpEnableTarget = <String, dynamic>{
  'name': 'composio',
  'kind': 'mcp',
  'action': 'enable',
  'state': 'pending',
  'launch': {'kind': 'remote', 'target': 'https://connect.example.test/mcp'},
};

class ConnectionRequestFixture extends ProfileBrowserFixture {
  Map<String, dynamic>? pending = connectionRequest();
  Map<String, dynamic> status = {...connectionRequest(), 'settled': false};
  final connectionCalls = <(String, Map<String, dynamic>)>[];
  final gateways = <String, ProfileGateway>{};
  final sequences = <(String, String), int>{};
  Completer<void>? responseGate, statusGate;
  bool reject = false, loseResponse = false;
  bool rejectStatus = false;
  String? runtimeOverride;

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    late final ProfileGateway result;
    result = ProfileGateway(
      scope: scope,
      discover: base.discover,
      get: base.read,
      close: base.close,
      connect: () async {
        if (result.onEvent != null) gateways[scope.profileName] = result;
        await base.connect();
      },
      rpc: (method, params) async {
        if (method == 'session.resume') {
          final snapshot = await base.call(method, params);
          final runtime = runtimeOverride ?? snapshot['session_id'] as String;
          return {
            ...snapshot,
            'session_id': runtime,
            'last_sequence': sequences[(scope.profileName, runtime)] ?? 0,
            'pending_connection': pending,
          };
        }
        if (method == 'connection.respond') {
          connectionCalls.add((method, Map.of(params)));
          await responseGate?.future;
          if (reject) throw StateError('Fixture connection refused');
          status = {
            ...status,
            'seq': (status['seq'] as int) + 1,
            'settled': true,
          };
          pending = null;
          if (loseResponse) {
            throw TimeoutException('Lost Continue acknowledgment');
          }
          return {'status': 'ok', 'settled': true};
        }
        if (method == 'connectors.connect') {
          connectionCalls.add((method, Map.of(params)));
          await responseGate?.future;
          if (reject) throw StateError('Fixture retry refused');
          return status;
        }
        if (method == 'connectors.operation.status') {
          connectionCalls.add((method, Map.of(params)));
          if (status['settled'] == true) {
            throw JsonRpcError(
              method,
              'Unknown operation',
              reason: 'UNKNOWN_OPERATION',
            );
          }
          final response = Map<String, dynamic>.of(status)
            ..remove('display')
            ..remove('tool_call_id')
            ..remove('timeout_seconds');
          await statusGate?.future;
          if (rejectStatus) throw StateError('Fixture status refused');
          return response;
        }
        return base.call(method, params);
      },
    );
    return result;
  }

  void event(ProfileChat chat, String type, Map<String, dynamic> data) {
    final profile = chat.key.workspace.profileName;
    final key = (profile, chat.runtime.runtimeId);
    final seq = (sequences[key] ?? 0) + 1;
    sequences[key] = seq;
    gateways[profile]!.onEvent!(
      StreamEvent(
        type: type,
        data: data,
        sessionId: chat.runtime.runtimeId,
        envelope: {
          'seq': seq,
          'replay_epoch': canonicalSnapshotFields['replay_epoch'],
          'authority_epoch': 1,
          'execution_generation': 0,
        },
      ),
    );
  }
}

Future<(ProfileWorkspaceController, AppPreferences)>
connectionRequestController(ConnectionRequestFixture fixture) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final appPreferences = AppPreferences(preferences);
  final controller = ProfileWorkspaceController(
    access: ConnectionAccess(
      connection: identityTestConnection(),
      dashboardOAuth: null,
    ),
    connectionIdentity: 'received-connection-request',
    preferences: preferences,
    appPreferences: appPreferences,
    gatewayFactory: fixture.gateway,
  );
  await controller.initialize();
  await controller.openSession(
    ProfileSessionKey(controller.current!.scope, 'newest'),
  );
  return (controller, appPreferences);
}

void registerConnectionRequestScenarios({
  bool native = false,
  Future<void> Function(WidgetTester, String, bool)? nativeCapture,
}) {
  if (!native) setUpAll(loadFormFamilyFonts);
  Future<void> mount(
    WidgetTester tester,
    ProfileWorkspaceController controller,
    Brightness brightness,
    double scale,
  ) => tester.pumpWidget(
    RepaintBoundary(
      key: formFamilyCapture,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: wingTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    ),
  );

  Future<void> capture(WidgetTester tester, String name) async {
    if (native) {
      await nativeCapture?.call(tester, name, false);
    } else {
      await captureFormFamily(tester, name);
    }
  }

  Future<void> settle(WidgetTester tester) => tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 5),
  );

  void setPhoneSize(WidgetTester tester) {
    if (!native) {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
  }

  testWidgets(
    'Conversation connection requests retain owner through pending failure and retry',
    (tester) async {
      setPhoneSize(tester);
      for (final brightness in Brightness.values) {
        for (final scale in [1.0, 2.0]) {
          final fixture = ConnectionRequestFixture();
          final (controller, preferences) = await connectionRequestController(
            fixture,
          );
          try {
            await mount(tester, controller, brightness, scale);
            await settle(tester);
            final closeButton = find.byTooltip('Close connection request');
            await tester.ensureVisible(closeButton);
            await settle(tester);
            expect(
              find.descendant(
                of: closeButton,
                matching: find.byIcon(Icons.close_rounded),
              ),
              findsOneWidget,
            );
            expect(find.text('Gmail · work'), findsOneWidget);
            expect(find.byTooltip('Authorize Gmail · work'), findsOneWidget);
            final stem = 'connection-request-${brightness.name}-$scale';
            await capture(tester, '$stem-request');
            fixture.responseGate = Completer<void>();
            fixture.reject = true;
            await tester.tap(closeButton);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 100));
            expect(
              find.byWidgetPredicate(
                (widget) =>
                    widget is CircularProgressIndicator &&
                    widget.semanticsLabel == 'Closing request…',
              ),
              findsOneWidget,
            );
            expect(
              find.descendant(
                of: find.byType(HostedConnectionRequestPanel),
                matching: find.byType(CircularProgressIndicator),
              ),
              findsOneWidget,
            );
            final progress = find.descendant(
              of: find.byType(HostedConnectionRequestPanel),
              matching: find.byType(CircularProgressIndicator),
            );
            expect(
              tester
                  .getRect(progress)
                  .overlaps(
                    Offset.zero &
                        tester.view.physicalSize / tester.view.devicePixelRatio,
                  ),
              isTrue,
            );
            expect(
              tester
                  .widget<IconButton>(
                    find.ancestor(
                      of: closeButton,
                      matching: find.byType(IconButton),
                    ),
                  )
                  .onPressed,
              isNull,
            );
            await tester.pump(const Duration(milliseconds: 200));
            await capture(tester, '$stem-pending');
            fixture.responseGate!.complete();
            await settle(tester);
            await tester.ensureVisible(closeButton);
            await settle(tester);
            expect(
              find.textContaining('Could not close the request.'),
              findsOneWidget,
            );
            await capture(tester, '$stem-failed');
            fixture.reject = false;
            fixture.responseGate = null;
            fixture
              ..statusGate = Completer<void>()
              ..rejectStatus = true;
            final moreActions = find.byTooltip('More connection actions');
            final checkStatus = find.text('Check connection status');
            await tester.ensureVisible(moreActions);
            await settle(tester);
            await tester.tap(moreActions);
            await settle(tester);
            await tester.tap(checkStatus);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 350));
            expect(
              find.text('Checking connection…').hitTestable(),
              findsOneWidget,
            );
            fixture.statusGate!.complete();
            await settle(tester);
            expect(
              find.textContaining('Could not check connection status.'),
              findsOneWidget,
            );

            fixture
              ..statusGate = null
              ..rejectStatus = false;
            await tester.ensureVisible(moreActions);
            await settle(tester);
            await tester.tap(moreActions);
            await settle(tester);
            await tester.tap(checkStatus);
            await settle(tester);
            expect(find.text('Connection status checked.'), findsOneWidget);
            await tester.ensureVisible(closeButton);
            await tester.tap(closeButton);
            await settle(tester);
            expect(find.byType(HostedConnectionRequestPanel), findsNothing);
            expect(find.byTooltip('Close connection request'), findsNothing);
            final responses = fixture.connectionCalls
                .where((call) => call.$1 == 'connection.respond')
                .toList();
            expect(responses, hasLength(2));
            for (final call in responses) {
              expect(call.$2, {
                'profile': 'personal',
                'owner': {'type': 'session', 'session_id': 'runtime-newest'},
                'op_id': 'mail-request',
                'result': {'settled_by': 'continue'},
              });
            }
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            controller.dispose();
            preferences.dispose();
          }
        }
      }
    },
  );

  testWidgets(
    'Conversation MCP enable approves the exact target and follows Hermes progress',
    (tester) async {
      setPhoneSize(tester);
      for (final brightness in Brightness.values) {
        for (final scale in [1.0, 2.0]) {
          final request = connectionRequest(
            id: 'mcp-enable',
            targets: [mcpEnableTarget],
          );
          final fixture = ConnectionRequestFixture()
            ..pending = request
            ..status = {...request, 'settled': false};
          final (controller, preferences) = await connectionRequestController(
            fixture,
          );
          try {
            await mount(tester, controller, brightness, scale);
            await settle(tester);
            final enable = find.byTooltip('Enable composio');
            await tester.ensureVisible(enable);
            await settle(tester);
            expect(find.text('Approval required to enable'), findsOneWidget);
            expect(find.byTooltip('Authorize composio'), findsNothing);
            final stem = 'connection-mcp-enable-${brightness.name}-$scale';
            await capture(tester, '$stem-request');
            final moreActions = find.byTooltip('More connection actions');
            expect(find.byTooltip('Skip composio'), findsNothing);
            expect(find.byTooltip('Check connection status'), findsNothing);
            await tester.ensureVisible(moreActions);
            await settle(tester);
            await tester.tap(moreActions);
            await settle(tester);
            expect(find.text('Skip composio').hitTestable(), findsOneWidget);
            expect(
              find.text('Check connection status').hitTestable(),
              findsOneWidget,
            );
            await capture(tester, '$stem-menu');
            await tester.binding.handlePopRoute();
            await settle(tester);
            await tester.ensureVisible(enable);

            fixture.responseGate = Completer<void>();
            fixture.reject = true;
            await tester.tap(enable);
            await tester.pump();
            expect(
              find.text('Enabling composio…').hitTestable(),
              findsOneWidget,
            );
            expect(
              tester
                  .widget<IconButton>(
                    find.ancestor(
                      of: enable,
                      matching: find.byType(IconButton),
                    ),
                  )
                  .onPressed,
              isNull,
            );
            await tester.pump(const Duration(milliseconds: 200));
            await capture(tester, '$stem-pending');
            fixture.responseGate!.complete();
            await settle(tester);
            expect(find.textContaining('Enable failed.'), findsOneWidget);
            await capture(tester, '$stem-failed');

            fixture
              ..responseGate = Completer<void>()
              ..reject = false;
            await tester.ensureVisible(enable);
            await tester.tap(enable);
            await tester.pump();
            final chat = controller.current!.chat!;

            // Stock enable publishes its target transitions and settlement
            // during connection.respond, before it returns the acknowledgment.
            void publish(String state, int sequence, {bool settled = false}) {
              fixture.event(chat, 'connection.update', {
                'op_id': 'mcp-enable',
                'seq': sequence,
                'deadline_at': request['deadline_at'],
                'settled': settled,
                'owner': {
                  'type': 'session',
                  'session_id': chat.runtime.runtimeId,
                },
                'targets': [
                  {...mcpEnableTarget, 'state': state},
                ],
              });
            }

            publish('initiated', 1);
            await tester.pump();
            expect(
              find.text('Enabling composio…').hitTestable(),
              findsOneWidget,
            );
            expect(find.text('Enabling…'), findsNothing);
            expect(enable, findsNothing);
            publish('connected', 2);
            publish('connected', 3, settled: true);
            await settle(tester);
            expect(find.text('Enabled'), findsOneWidget);
            expect(find.text('Enabling composio…'), findsNothing);
            expect(find.byTooltip('Close connection request'), findsNothing);
            fixture.responseGate!.complete();
            await settle(tester);
            expect(find.text('Enabled'), findsOneWidget);
            await capture(tester, '$stem-enabled');

            final approvals = fixture.connectionCalls
                .where((call) => call.$1 == 'connection.respond')
                .map((call) => call.$2);
            expect(approvals, [
              for (var attempt = 0; attempt < 2; attempt++)
                {
                  'profile': 'personal',
                  'owner': {'type': 'session', 'session_id': 'runtime-newest'},
                  'op_id': 'mcp-enable',
                  'result': {
                    'targets': [
                      {'name': 'composio', 'status': 'approved'},
                    ],
                  },
                },
            ]);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            controller.dispose();
            preferences.dispose();
          }
        }
      }
    },
  );
}
