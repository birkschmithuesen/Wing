import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:wing/core/screens/administration/admin_hosted_connector_accounts_page.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/models/hosted_connector_accounts.dart';
import 'support/form_family_capture.dart';
import 'support/hosted_connection_request_scenarios.dart';
import 'support/hosted_connector_fixture.dart';

class _AuthorizationBrowser extends UrlLauncherPlatform {
  final calls = <(String, LaunchOptions)>[];
  final gate = Completer<bool>();
  @override
  LinkDelegate? get linkDelegate => null;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) {
    calls.add((url, options));
    return gate.future;
  }
}

Future<void> _mountRequest(
  WidgetTester tester,
  ProfileWorkspaceController controller, {
  double scale = 1,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: formFamilyCapture,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: wingTheme(Brightness.dark),
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
  await tester.pumpAndSettle();
}

Future<void> _tapAction(WidgetTester tester, String label) async {
  final action = find.byTooltip(label);
  await tester.ensureVisible(action);
  await tester.pumpAndSettle();
  expect(action.hitTestable(), findsOneWidget);
  await tester.tap(action);
}

void main() {
  registerConnectionRequestScenarios();

  test(
    'status overlays preserve request metadata and reject stale or unrelated updates',
    () {
      final request = HostedConnectionOperation.fromJson(
        connectionRequest(suggested: ['gmail']),
      );
      final status =
          {
              ...connectionRequest(seq: 1, suggested: ['gmail']),
              'settled': false,
            }
            ..remove('display')
            ..remove('tool_call_id');
      final next = request.applyStatus(status);
      expect(next.isDirectory, isTrue);
      expect(next.suggested, ['gmail']);
      expect(next.toolCallId, 'connect-1');
      expect(identical(next.applyStatus(status), next), isTrue);
      expect(
        identical(
          next.applyStatus({...status, 'op_id': 'other', 'seq': 2}),
          next,
        ),
        isTrue,
      );
      final settled = next.applyStatus({...status, 'seq': 2, 'settled': true});
      expect(
        identical(settled.applyStatus({...status, 'seq': 3}), settled),
        isTrue,
      );
    },
  );

  test('authorization only exposes supported remote account URLs', () {
    for (final url in [
      'javascript:alert(1)',
      'file:///private',
      'https:relative',
    ]) {
      final target = HostedConnectionTarget.fromJson({
        'name': 'mail',
        'kind': 'connector',
        'action': 'connect',
        'state': 'pending',
        'connect_url': url,
      });
      expect(target.needsAuthorization, isFalse);
    }
    expect(
      HostedConnectionTarget.fromJson({
        'name': 'plugin',
        'kind': 'plugin',
        'action': 'install',
        'state': 'pending',
        'connect_url': 'https://example.test',
      }).needsAuthorization,
      isFalse,
    );
  });

  test(
    'Continue is single flight and a newer request retires its late response',
    () async {
      final fixture = ConnectionRequestFixture();
      final (controller, preferences) = await connectionRequestController(
        fixture,
      );
      addTearDown(() {
        controller.dispose();
        preferences.dispose();
      });
      final chat = controller.current!.chat!;
      final operation = chat.connectionOperation!;
      fixture.responseGate = Completer<void>();
      final first = controller.continueConnectionOperation(chat, operation);
      final firstFailure = expectLater(first, throwsStateError);
      await expectLater(
        controller.continueConnectionOperation(chat, operation),
        throwsStateError,
      );
      expect(fixture.connectionCalls, hasLength(1));
      fixture.event(
        chat,
        'connection.request',
        connectionRequest(id: 'next-operation'),
      );
      fixture.responseGate!.complete();
      await firstFailure;
      expect(chat.connectionOperation!.id, 'next-operation');
      expect(chat.connectionOperation!.settled, isFalse);
      expect(chat.connectionOperationWorking, isFalse);
      expect(fixture.connectionCalls, hasLength(1));
    },
  );

  test(
    'updates settle the current operation without losing directory metadata',
    () async {
      final directory = connectionRequest(suggested: ['gmail']);
      final fixture = ConnectionRequestFixture()
        ..pending = directory
        ..status = {...directory, 'settled': false};
      final (controller, preferences) = await connectionRequestController(
        fixture,
      );
      addTearDown(() {
        controller.dispose();
        preferences.dispose();
      });
      final chat = controller.current!.chat!;
      fixture.event(chat, 'connection.update', {
        ...fixture.status,
        'op_id': 'different',
        'seq': 10,
      });
      expect(chat.connectionOperation!.sequence, 0);
      fixture.event(
        chat,
        'connection.update',
        {...fixture.status, 'seq': 1, 'settled': true}
          ..remove('display')
          ..remove('tool_call_id'),
      );
      expect(chat.connectionOperation!.settled, isTrue);
      expect(chat.connectionOperation!.isDirectory, isTrue);
      expect(
        controller.canContinueConnectionOperation(
          chat,
          chat.connectionOperation!,
        ),
        isFalse,
      );
    },
  );

  test(
    'accepted reconnect snapshot clears requests absent from canonical state',
    () async {
      final fixture = ConnectionRequestFixture();
      final (controller, preferences) = await connectionRequestController(
        fixture,
      );
      addTearDown(() {
        controller.dispose();
        preferences.dispose();
      });
      final chat = controller.current!.chat!;
      expect(chat.connectionOperation, isNotNull);
      fixture.pending = null;
      await controller.refresh();
      expect(chat.connectionOperation, isNull);
    },
  );
  test(
    'lost settled ACK recovers through UNKNOWN_OPERATION and canonical snapshot',
    () async {
      final fixture = ConnectionRequestFixture()..loseResponse = true;
      final (controller, preferences) = await connectionRequestController(
        fixture,
      );
      addTearDown(() {
        controller.dispose();
        preferences.dispose();
      });
      final chat = controller.current!.chat!;
      await expectLater(
        controller.continueConnectionOperation(chat, chat.connectionOperation!),
        throwsA(isA<TimeoutException>()),
      );
      expect(chat.connectionOperation, isNotNull);
      await controller.refreshConnectionOperation(
        chat,
        chat.connectionOperation!,
      );
      expect(chat.connectionOperation, isNull);
      expect(
        fixture.connectionCalls.where(
          (call) => call.$1 == 'connection.respond',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'late status from a replaced runtime cannot settle its replacement',
    () async {
      final fixture = ConnectionRequestFixture();
      final (controller, preferences) = await connectionRequestController(
        fixture,
      );
      addTearDown(() {
        controller.dispose();
        preferences.dispose();
      });
      final chat = controller.current!.chat!;
      fixture.status = {...fixture.status, 'seq': 1};
      fixture.statusGate = Completer<void>();
      final refresh = controller.refreshConnectionOperation(
        chat,
        chat.connectionOperation!,
      );
      final retired = expectLater(refresh, throwsStateError);
      fixture.runtimeOverride = 'replacement-runtime';
      await controller.refresh();
      fixture.statusGate!.complete();
      await retired;
      expect(chat.runtime.runtimeId, 'replacement-runtime');
      expect(chat.connectionOperation!.sequence, 0);
      expect(chat.connectionOperationWorking, isFalse);
    },
  );

  test(
    'read-only conversations may check status but cannot continue',
    () async {
      final fixture = ConnectionRequestFixture();
      final (controller, preferences) = await connectionRequestController(
        fixture,
      );
      addTearDown(() {
        controller.dispose();
        preferences.dispose();
      });
      final chat = controller.current!.chat!;
      fixture.gateways['personal']!.canonical.refused(
        chat.runtime.runtimeId,
        JsonRpcError(
          'session.mutate',
          'Read only',
          reason: 'session_read_only',
        ),
      );
      await controller.refresh();
      expect(chat.readOnlyReason, 'session_read_only');
      expect(
        controller.canContinueConnectionOperation(
          chat,
          chat.connectionOperation!,
        ),
        isFalse,
      );
      expect(
        controller.canRefreshConnectionOperation(
          chat,
          chat.connectionOperation!,
        ),
        isTrue,
      );
      await expectLater(
        controller.continueConnectionOperation(chat, chat.connectionOperation!),
        throwsStateError,
      );
      await controller.refreshConnectionOperation(
        chat,
        chat.connectionOperation!,
      );
      expect(fixture.connectionCalls.map((call) => call.$1), [
        'connectors.operation.status',
      ]);
    },
  );
  testWidgets(
    'authorization opens the received account URL and retires late failure',
    (tester) async {
      final fixture = ConnectionRequestFixture();
      final (controller, preferences) = await connectionRequestController(
        fixture,
      );
      final browser = _AuthorizationBrowser();
      final original = UrlLauncherPlatform.instance;
      UrlLauncherPlatform.instance = browser;
      addTearDown(() {
        UrlLauncherPlatform.instance = original;
        controller.dispose();
        preferences.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileWorkspaceScreen(
            controller: controller,
            createBotsSession: () => BotsSession((_) async => const []),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Authorize Gmail · work'));
      await tester.tap(find.byTooltip('Authorize Gmail · work'));
      await tester.pump();
      expect(
        browser.calls.single.$1,
        'https://accounts.example.test/authorize',
      );
      expect(
        browser.calls.single.$2.mode,
        PreferredLaunchMode.externalApplication,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is CircularProgressIndicator &&
              widget.semanticsLabel == 'Opening authorization…',
        ),
        findsOneWidget,
      );
      expect(fixture.connectionCalls, isEmpty);
      final chat = controller.current!.chat!;
      fixture.event(
        chat,
        'connection.request',
        connectionRequest(id: 'replacement'),
      );
      await tester.pump();
      browser.gate.complete(false);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Could not open the sign-in page.'),
        findsNothing,
      );
      expect(chat.connectionOperation!.id, 'replacement');
      expect(chat.connectionOperation!.targets.single.connected, isFalse);
      expect(find.byTooltip('Close connection request'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Install collects the declared credentials and keeps the form usable with the keyboard',
    (tester) async {
      final request = connectionRequest(
        id: 'install-tools',
        targets: [
          {
            'name': 'research',
            'kind': 'mcp',
            'action': 'install',
            'state': 'pending',
            'required_env': [
              {
                'name': 'RESEARCH_API_KEY',
                'required': true,
                'secret': true,
                'default': '',
                'prompt': 'Research API key',
              },
              {
                'name': 'REGION',
                'required': false,
                'secret': false,
                'default': 'apac',
              },
            ],
          },
        ],
      );
      final fixture = ConnectionRequestFixture()
        ..pending = request
        ..status = {...request, 'settled': false};
      final (controller, preferences) = await connectionRequestController(
        fixture,
      );
      addTearDown(() {
        controller.dispose();
        preferences.dispose();
      });
      await _mountRequest(tester, controller, scale: 2);
      await _tapAction(tester, 'Install research');
      await tester.pumpAndSettle();
      expect(fixture.connectionCalls, isEmpty);
      final field = find.byKey(const ValueKey('RESEARCH_API_KEY'));
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: field, matching: find.byType(TextField)),
            )
            .obscureText,
        isTrue,
      );
      final confirm = find.byTooltip('Install research');
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(of: confirm, matching: find.byType(IconButton)),
            )
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(field);
      await tester.enterText(field, 'fixture-key');
      tester.view.viewInsets = const FakeViewPadding(bottom: 245);
      await tester.pumpAndSettle();
      await tester.ensureVisible(confirm);
      await tester.pumpAndSettle();
      expect(confirm.hitTestable(), findsOneWidget);
      await captureFormFamily(tester, 'connection-mcp-install-keyboard');
      fixture.responseGate = Completer<void>();
      await tester.tap(confirm);
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is CircularProgressIndicator &&
              widget.semanticsLabel == 'Installing research…',
        ),
        findsOneWidget,
      );
      expect(fixture.connectionCalls.single.$1, 'connection.respond');
      expect(fixture.connectionCalls.single.$2, {
        'profile': 'personal',
        'owner': {'type': 'session', 'session_id': 'runtime-newest'},
        'op_id': 'install-tools',
        'result': {
          'targets': [
            {
              'name': 'research',
              'status': 'approved',
              'env': {'RESEARCH_API_KEY': 'fixture-key', 'REGION': 'apac'},
            },
          ],
        },
      });
      fixture.responseGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Install research'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Retry repairs the named hosted account and Skip targets it', (
    tester,
  ) async {
    final target = {
      'name': 'gmail',
      'kind': 'connector',
      'action': 'reconnect',
      'state': 'expired',
      'alias': 'work',
      'connection_id': 'work-id',
    };
    final request = connectionRequest(targets: [target]);
    final fixture = ConnectionRequestFixture()
      ..pending = request
      ..status = {
        ...request,
        'seq': 1,
        'settled': false,
        'targets': [
          {
            ...target,
            'state': 'initiated',
            'connect_url': 'https://accounts.example.test/retry',
          },
        ],
      };
    final (controller, preferences) = await connectionRequestController(
      fixture,
    );
    addTearDown(() {
      controller.dispose();
      preferences.dispose();
    });
    await _mountRequest(tester, controller);
    await _tapAction(tester, 'Retry gmail · work');
    await tester.pumpAndSettle();
    expect(fixture.connectionCalls.single.$1, 'connectors.connect');
    expect(fixture.connectionCalls.single.$2, {
      'profile': 'personal',
      'owner': {'type': 'session', 'session_id': 'runtime-newest'},
      'connectors': ['gmail'],
      'reconnect': true,
      'alias': 'work',
    });
    expect(find.byTooltip('Authorize gmail · work'), findsOneWidget);
    await _tapAction(tester, 'More connection actions');
    await tester.pumpAndSettle();
    fixture.responseGate = Completer<void>();
    await tester.tap(find.text('Skip gmail · work'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Skipping gmail · work…').hitTestable(), findsOneWidget);
    fixture.responseGate!.complete();
    await tester.pumpAndSettle();
    expect(fixture.connectionCalls.last.$1, 'connection.respond');
    expect(fixture.connectionCalls.last.$2, {
      'profile': 'personal',
      'owner': {'type': 'session', 'session_id': 'runtime-newest'},
      'op_id': 'mail-request',
      'result': {
        'targets': [
          {'name': 'gmail', 'status': 'skipped'},
        ],
      },
    });
    expect(find.byTooltip('Authorize gmail · work'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'Browse apps opens the captured directory with suggestions first',
    (tester) async {
      final request = connectionRequest(suggested: ['tasks']);
      final fixture = ConnectionRequestFixture()
        ..pending = request
        ..status = {...request, 'settled': false};
      final directory = HostedConnectorFixture();
      final gate = Completer<void>();
      directory.rpcOverride = (method, params) async {
        if (method != 'connectors.catalog') {
          return directory.rpc(method, params);
        }
        await gate.future;
        return {
          'connectors': [
            for (final (slug, title) in [
              ('calendar', 'Calendar'),
              ('tasks', 'Tasks'),
            ])
              {
                'slug': slug,
                'name': title,
                'description': '',
                'category': 'productivity',
              },
          ],
        };
      };
      final (controller, preferences) = await connectionRequestController(
        fixture,
      );
      controller.healthSession(repository: directory.server);
      addTearDown(() {
        controller.dispose();
        preferences.dispose();
      });
      await _mountRequest(tester, controller);
      await _tapAction(tester, 'Browse apps');
      await tester.pump();
      expect(
        find.byType(AdminHostedConnectorAccountsPage, skipOffstage: false),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.text('Connected apps', findRichText: true).hitTestable(),
        findsOneWidget,
      );
      gate.complete();
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Tasks')).dy,
        lessThan(tester.getTopLeft(find.text('Calendar')).dy),
      );
      expect(fixture.connectionCalls, isEmpty);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close connection request'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
