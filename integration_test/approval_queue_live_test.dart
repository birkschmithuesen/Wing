import 'package:wing/core/models/model_catalog.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/models/model_choice.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/widgets/gateway_approval_panel.dart';

/// Opt-in device test. Supply an explicitly authorized connection JSON in the
/// app's private files directory; never embed credentials in build arguments.
/// Each scenario uses a disposable Luna conversation and two print-only scripts
/// or removals of nonexistent test-owned temporary paths. Never approves
/// unrelated commands or chats.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('RUN_LIVE_APPROVAL_QA');
  // Enable only with explicit authorization to change this shared profile setting.
  const manual = bool.fromEnvironment('APPROVAL_QA_MANUAL');
  const profile = String.fromEnvironment('APPROVAL_QA_PROFILE');
  for (final parallel in [false, true]) {
    testWidgets(
      '${parallel ? 'parallel terminal' : 'sequential code'} approvals remain actionable on Android',
      (tester) async {
        final support = await getApplicationSupportDirectory();
        final fixture = File('${support.path}/approval-connection.json');
        final map =
            jsonDecode(await fixture.readAsString()) as Map<String, dynamic>;
        // This opt-in fixture has explicit private credentials; the metadata
        // reader never accepts secrets. Parse its current fields separately.
        final metadata = Map<String, dynamic>.of(map)
          ..remove('api_key')
          ..remove('dashboard_password')
          ..remove('gateway_headers')
          ..remove('dashboard_oauth');
        final connection = SavedConnection.fromMap(metadata).copyWith(
          apiKey: map['api_key'] as String? ?? '',
          dashboardPassword: map['dashboard_password'] as String?,
          gatewayHeaders: Map<String, String>.from(
            map['gateway_headers'] as Map? ?? {},
          ),
        );
        SharedPreferences.setMockInitialValues({});
        final wireRequests = <String>{};
        String? runtime;
        ModelChoice? luna;
        final fixturePreferences = await SharedPreferences.getInstance();
        final appPreferences = AppPreferences(fixturePreferences);
        addTearDown(appPreferences.dispose);
        final controller = ProfileWorkspaceController(
          appPreferences: appPreferences,
          connectionIdentity: 'approval-device-qa',
          access: ConnectionAccess(
            connection: connection,
            dashboardOAuth: null,
          ),
          preferences: fixturePreferences,
          gatewayFactory: (scope) {
            final wire = ProfileGateway.forConnection(
              ConnectionAccess(connection: connection, dashboardOAuth: null),
              scope,
            );
            final gateway = ProfileGateway(
              scope: scope,
              discover: wire.discover,
              get: wire.read,
              connect: wire.connect,
              close: wire.close,
              rpc: (method, params) async {
                final result = await wire.call(method, {
                  ...params,
                  if (method == 'session.create') ...{
                    'model': luna!.model,
                    'provider': luna.provider,
                    'reasoning': 'low',
                    'service_tier': 'normal',
                    'title': 'Wing approval queue device QA',
                  },
                });
                if (method == 'approval.pending' &&
                    params['session_id'] == runtime) {
                  debugPrint(
                    'APPROVAL_QA pending=${(result['approvals'] as List?)?.length}',
                  );
                }
                if (method == 'request.answer') {
                  debugPrint('APPROVAL_QA answer_status=${result['status']}');
                }
                return result;
              },
            );
            wire.onConnectionChanged = (connected) =>
                gateway.onConnectionChanged?.call(connected);
            wire.onEvent = (event) {
              if (event.type == 'approval' && event.sessionId == runtime) {
                wireRequests.add(event.data['request_id'].toString());
                debugPrint(
                  'APPROVAL_QA wire_requests=${wireRequests.length} server_request=${event.data['server_request_id'] != null}',
                );
              }
              gateway.onEvent?.call(event);
            };
            return gateway;
          },
        );
        addTearDown(controller.dispose);
        await controller.initialize();
        expect(controller.error, isNull);
        if (profile.isNotEmpty) {
          expect(await controller.switchProfile(profile), isTrue);
        }
        final options = ModelCatalog.fromOptions(
          await controller.current!.gateway.read('model/options'),
        ).choices;
        luna = options.firstWhere((choice) => choice.model == 'gpt-5.6-luna');
        final chat = await controller.createChat(canDispatch: () => true);
        runtime = chat.runtime.runtimeId;
        addTearDown(() async {
          if (chat.runtime.blocksTurnAdmission) await controller.stop(chat);
          await controller.current!.gateway.call('session.close', {
            'session_id': chat.runtime.runtimeId,
          });
        });
        expect(
          chat.model,
          'gpt-5.6-luna',
          reason:
              'Hermes must confirm the session-specific model before any prompt',
        );
        debugPrint('APPROVAL_QA session_model=Luna');
        final captureKey = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: captureKey,
            child: MaterialApp(
              home: ProfileWorkspaceScreen(controller: controller),
            ),
          ),
        );
        debugPrint('APPROVAL_QA screen_ready');
        final nonce = DateTime.now().microsecondsSinceEpoch;
        final scripts = [
          for (final suffix in ['one', 'two'])
            "print('WING_APPROVAL_QA_${nonce}_$suffix')",
        ];
        final commands = parallel
            ? [
                for (final suffix in ['one', 'two'])
                  'rm -rf -- /tmp/wing-approval-qa-$nonce-$suffix',
              ]
            : [
                for (final script in scripts)
                  "execute_code <<'PY'\n$script\nPY",
              ];
        final config = await controller.current!.gateway.read('config');
        final originalMode = config['approvals']['mode'] as String;
        debugPrint('APPROVAL_QA mode=$originalMode');
        var restoreMode = false;
        Future<void> restoreApprovalMode() async {
          if (!restoreMode) return;
          await controller.current!.gateway.call('config.set', {
            'session_id': chat.runtime.runtimeId,
            'key': 'approvals.mode',
            'value': originalMode,
          });
          restoreMode = false;
          debugPrint('APPROVAL_QA mode_restored=$originalMode');
        }

        if (manual && originalMode != 'manual') {
          restoreMode = true;
          addTearDown(restoreApprovalMode);
          await controller.current!.gateway.call('config.set', {
            'session_id': chat.runtime.runtimeId,
            'key': 'approvals.mode',
            'value': 'manual',
          });
          debugPrint('APPROVAL_QA temporary_mode=manual');
        }
        final prompt = parallel
            ? 'Command-approval UI test: use exactly two separate terminal tool calls in the same parallel batch, one per exact command below. These are unique nonexistent temporary paths owned by this test. Do not combine commands or use other tools. Wait for both results, then reply DONE.\n${commands.join('\n')}'
            : 'Command-approval UI test: use exactly two separate execute_code tool calls in the same parallel batch. '
                  'Each runs only one print statement below. Do not combine them, use terminal, or use other tools. '
                  'Wait for both results, then reply DONE.\n${scripts.join('\n')}';
        await controller.updateDraft(chat, prompt);
        await controller.send(chat);
        expect(chat.runtime.error, isNull);

        Future<void> until(bool Function() ready, String reason) async {
          final deadline = DateTime.now().add(const Duration(seconds: 90));
          while (!ready() && DateTime.now().isBefore(deadline)) {
            await tester.pump(const Duration(milliseconds: 200));
          }
          debugPrint(
            'APPROVAL_QA $reason wire=${wireRequests.length} queue=${chat.runtime.approvals.length} status=${chat.runtime.execution.name}',
          );
          expect(ready(), isTrue, reason: reason);
        }

        final answered = <String>{};
        for (var index = 0; index < 2; index++) {
          await until(
            () =>
                chat.runtime.approval != null ||
                !chat.runtime.blocksTurnAdmission,
            'approval_${index + 1}_visible',
          );
          if (parallel && index == 0) {
            await until(
              () =>
                  wireRequests.length == 2 || !chat.runtime.blocksTurnAdmission,
              'two_live_requests_received',
            );
            expect(
              wireRequests,
              hasLength(2),
              reason:
                  'The test must produce concurrent approvals, not two sequential turns',
            );
          }
          // Let the production pending-list reconciliation finish before clicking.
          for (var tick = 0; tick < 15; tick++) {
            await tester.pump(const Duration(milliseconds: 200));
          }
          expect(
            chat.runtime.approval,
            isNotNull,
            reason: 'A pending read must not erase an unanswered live request',
          );
          final request = chat.runtime.approval!;
          expect(
            commands,
            contains(request.request.command),
            reason:
                'Only the two exact disposable test commands may be approved',
          );
          expect(answered.add(request.requestId), isTrue);
          final panel = find.byType(GatewayApprovalPanel);
          expect(panel, findsOneWidget);
          final button = find.descendant(
            of: panel,
            matching: find.widgetWithText(FilledButton, 'Allow once'),
          );
          await tester.ensureVisible(button);
          await tester.pump();
          final directory = await getExternalStorageDirectory();
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(captureKey),
          );
          final rendered = await boundary.toImage();
          final screenshot = (await rendered.toByteData(
            format: ui.ImageByteFormat.png,
          ))!.buffer.asUint8List();
          rendered.dispose();
          await File(
            '${directory!.path}/live-${parallel ? 'parallel' : 'sequential'}-approval-${index + 1}.png',
          ).writeAsBytes(screenshot);
          await tester.tap(button);
          await until(
            () => !chat.runtime.approvalResponding,
            'approval_${index + 1}_answered',
          );
          expect(chat.runtime.error, isNull);
        }
        await restoreApprovalMode();
        await until(() => !chat.runtime.blocksTurnAdmission, 'turn_finished');
        expect(chat.runtime.execution, ChatExecution.completed);
        expect(chat.runtime.approval, isNull);
        expect(answered.length, 2);
        expect(chat.model, 'gpt-5.6-luna');
        debugPrint(
          'APPROVAL_QA PASS two distinct requests approved through Android buttons; turn completed',
        );
      },
      skip: !enabled,
      timeout: const Timeout(Duration(minutes: 6)),
    );
  }
}
