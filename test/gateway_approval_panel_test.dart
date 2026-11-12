import 'support/bots_fixture.dart';
import 'package:wing/core/services/bots_repository.dart';
import 'package:wing/core/models/bots.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'package:wing/core/widgets/gateway_approval_panel.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';

import 'profile_workspace_controller_test.dart' show Host;

const _capture = bool.fromEnvironment('CAPTURE_APPROVALS');

class _ApprovalHost extends Host {
  bool rejectDecision = false;

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    late final ProfileGateway gateway;
    gateway = ProfileGateway(
      scope: scope,
      discover: base.discover,
      connect: () async {
        await base.connect();
        if (gateway.onEvent != null) gateways[scope.profileName] = gateway;
      },
      close: base.close,
      get: (path, query) async {
        if (path == 'model/info') {
          return {'provider': 'fixture', 'model': 'fixture/model'};
        }
        if (path == 'model/options') {
          return {
            'providers': [
              {
                'slug': 'fixture',
                'name': 'Fixture',
                'models': ['fixture/model'],
              },
            ],
          };
        }
        return base.read(path, query);
      },
      rpc: (method, params) async {
        if (method == 'approval.respond' && rejectDecision) {
          calls.add((scope.profileName, method, params));
          await approvalDelay?.future;
          throw StateError('Decision was rejected. Try again.');
        }
        return base.call(method, params);
      },
    );
    return gateway;
  }
}

class _ApprovalBots extends BotsSession {
  _ApprovalBots(this.bot) : super((_) async => const []);
  final BotRecord? bot;
  final _fixture = BotsFixture();

  @override
  BotsRepository repository(String identity) => _fixture.repository;

  @override
  BotRecord? cachedAppearance(ProfileSessionKey key) => bot;

  @override
  Future<BotRecord?> botForConversation(ProfileSessionKey key) async => bot;
}

Finder _decisionButton(String label) => find.byWidgetPredicate(
  (widget) => widget is IconButton && widget.tooltip == label,
);

void main() {
  setUpAll(() async {
    if (!_capture) return;
    const directory = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      WingTypography.sans: 'Roboto-Regular.ttf',
      'monospace': 'RobotoMono-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(
              '$directory/${entry.value}',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });

  for (final (botChat, brightness) in [
    for (final botChat in [false, true])
      for (final brightness in Brightness.values) (botChat, brightness),
  ]) {
    for (final scale in [1.0, 2.0]) {
      for (final fails in [false, true]) {
        testWidgets(
          '${botChat ? 'bot' : 'normal'} approval decision ${fails ? 'failure and retry' : 'success'} retains feedback: $brightness/$scale',
          (tester) async {
            tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            SharedPreferences.setMockInitialValues({});
            final preferences = await SharedPreferences.getInstance();
            final appPreferences = AppPreferences(preferences);
            addTearDown(appPreferences.dispose);
            final host = _ApprovalHost();
            late ProfileWorkspaceController controller;
            await tester.runAsync(() async {
              controller = ProfileWorkspaceController(
                connectionIdentity: 'fixture',
                access: ConnectionAccess(
                  connection: SavedConnection(
                    id: 'host',
                    label: 'Home',
                    host: 'localhost',
                    port: 1,
                    apiKey: '',
                  ),
                  dashboardOAuth: null,
                ),
                preferences: preferences,
                appPreferences: appPreferences,
                gatewayFactory: host.gateway,
              );
              await controller.initialize();
              final chat = await controller.createChat(canDispatch: () => true);
              emitChatEvent(controller, chat, 'session.title', {
                'session_id': chat.key.sessionId,
                'title': 'Review source verification',
              });
              final records = List.generate(
                80,
                (i) => "records.append({'source': $i, 'verified': True})",
              ).join('\n');
              host.pendingApprovals = [];
              for (final id in ['one', 'two']) {
                final approval = <String, dynamic>{
                  'request_id': id,
                  'command':
                      "execute_code <<'PY'\n# Write the source-verification artifact\nimport json, os\n$records\nPY",
                  'choices': ['once', 'session', 'always', 'deny'],
                };
                host.pendingApprovals!.add(approval);
                host.event('a', 'approval', approval);
              }
            });
            addTearDown(controller.dispose);
            final chat = controller.current!.chat!;
            final bot = botChat
                ? BotRecord(
                    scope: chat.key.workspace,
                    instance: 'Home',
                    profile: HermesProfile(
                      name: chat.key.workspace.profileName,
                    ),
                    title: 'Pace',
                    shape: 'hexagon',
                    color: '#f6b26b',
                    pinned: false,
                    hidden: false,
                    hasAvatar: false,
                    revision: 1,
                    metadata: const {},
                    chat: chat.key,
                    resolvedChat: chat.key,
                  )
                : null;
            final frame = GlobalKey();
            await tester.pumpWidget(
              MaterialApp(
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                    disableAnimations: scale == 2,
                  ),
                  child: child!,
                ),
                home: RepaintBoundary(
                  key: frame,
                  child: ProfileWorkspaceScreen(
                    controller: controller,
                    createBotsSession: () => _ApprovalBots(bot),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(
              find.byType(BotConversationScope),
              botChat ? findsOneWidget : findsNothing,
            );
            expect(find.text('Review command'), findsOneWidget);
            expect(find.byType(ApprovalCommandDetails), findsOneWidget);
            expect(find.text('Asking a question'), findsNothing);
            final command = find.byWidgetPredicate(
              (widget) =>
                  widget is SelectableText &&
                  widget.data?.contains('records.append') == true,
            );
            expect(command, findsOneWidget);
            expect(
              tester.widget<SelectableText>(command).data,
              chat.runtime.approval!.request.command,
            );
            for (final label in [
              'Approve once',
              'Approve for session',
              'Always approve',
              'Reject',
            ]) {
              await tester.ensureVisible(find.byTooltip(label));
              await tester.pumpAndSettle();
              expect(find.byTooltip(label).hitTestable(), findsOneWidget);
              expect(find.text(label), findsNothing);
            }
            expect(tester.takeException(), isNull);
            // Responding disables every scope, including denial.
            host.approvalDelay = Completer<void>();
            addTearDown(() {
              final pending = host.approvalDelay;
              if (pending != null && !pending.isCompleted) pending.complete();
            });
            host.rejectDecision = fails;
            await tester.ensureVisible(_decisionButton('Approve once'));
            await tester.pumpAndSettle();
            final decisionBounds = tester.getRect(
              _decisionButton('Approve once'),
            );
            final headerSlot = find.byKey(
              const ValueKey('studio-loading-slot'),
            );
            final headerBounds = tester.getRect(headerSlot);
            await tester.tap(_decisionButton('Approve once'));
            await tester.pump();
            await tester.pump();
            expect(
              find.bySemanticsLabel('Sending approval decision'),
              findsOneWidget,
            );
            final progress = find.descendant(
              of: headerSlot,
              matching: find.byType(StudioLoading),
            );
            expect(progress, findsOneWidget);
            expect(
              headerBounds.contains(tester.getRect(progress).center),
              isTrue,
            );
            expect(tester.getSize(progress).shortestSide, greaterThan(0));
            expect(
              tester.getRect(_decisionButton('Approve once')),
              decisionBounds,
            );
            expect(tester.getRect(headerSlot), headerBounds);
            if (_capture && !fails) {
              await tester.runAsync(() async {
                final render =
                    frame.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary;
                final image = await render.toImage();
                final data = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final file = File(
                  'build/design-previews/approval-review/${botChat ? 'bot' : 'normal'}-${brightness.name}-$scale-held.png',
                );
                await file.parent.create(recursive: true);
                await file.writeAsBytes(data!.buffer.asUint8List());
                image.dispose();
              });
            }
            await tester.runAsync(
              () => controller.updateDraft(
                controller.current!.chat!,
                'Draft while reviewing',
              ),
            );
            await tester.pump();
            for (final tooltip in [
              'Approve once',
              'Approve for session',
              'Always approve',
              'Reject',
            ]) {
              expect(
                tester.widget<IconButton>(_decisionButton(tooltip)).onPressed,
                isNull,
              );
            }
            await tester.tap(_decisionButton('Approve once'));
            await tester.pump();
            expect(
              host.calls.where((call) => call.$2 == 'approval.respond'),
              hasLength(1),
            );
            host.approvalDelay!.complete();
            await tester.pumpAndSettle();
            expect(
              find.bySemanticsLabel('Sending approval decision'),
              findsNothing,
            );
            expect(
              host.calls.where((call) => call.$2 == 'approval.respond'),
              hasLength(1),
            );
            if (fails) {
              expect(find.text('1/2'), findsOneWidget);
              expect(
                find.text('Decision was rejected. Try again.'),
                findsOneWidget,
              );
              host.rejectDecision = false;
              host.approvalDelay = null;
              await tester.pump(const Duration(seconds: 5));
              await tester.pumpAndSettle();
              await tester.ensureVisible(_decisionButton('Approve once'));
              await tester.tap(_decisionButton('Approve once'));
              await tester.pumpAndSettle();
              expect(
                host.calls.where((call) => call.$2 == 'approval.respond'),
                hasLength(2),
              );
            }
            expect(
              controller.current!.chat!.composer.observation.text,
              'Draft while reviewing',
            );
            expect(find.text('1/2'), findsNothing);
            expect(find.text('2/2'), findsOneWidget);
            expect(
              controller.current!.chat!.runtime.approval?.requestId,
              'two',
            );
            await tester.pumpWidget(const SizedBox.shrink());
          },
        );
      }
    }
  }

  testWidgets('leaving during an approval does not send a second decision', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final appPreferences = AppPreferences(preferences);
    addTearDown(appPreferences.dispose);
    final host = _ApprovalHost();
    final controller = ProfileWorkspaceController(
      connectionIdentity: 'approval-departure',
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'host',
          label: 'Home',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    final chat = await controller.createChat(canDispatch: () => true);
    host.event('a', 'approval', {
      'request_id': 'departure',
      'command': 'echo review',
      'choices': ['once', 'session', 'always', 'deny'],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final pending = Completer<void>();
    host.approvalDelay = pending;
    addTearDown(() {
      if (!pending.isCompleted) pending.complete();
    });
    await tester.tap(_decisionButton('Approve once'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(StudioLoading), findsOneWidget);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Elsewhere'))),
    );
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('Elsewhere'), findsOneWidget);
    expect(find.bySemanticsLabel('Sending approval decision'), findsNothing);
    expect(
      host.calls.where((call) => call.$2 == 'approval.respond'),
      hasLength(1),
    );
    expect(chat.runtime.approvalResponding, isFalse);
    expect(tester.takeException(), isNull);
  });
}
