import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'support/composer_fixture.dart';
import 'support/form_family_capture.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/models/chat_intelligence.dart';
import 'package:wing/core/models/model_choice.dart';
import 'package:wing/core/widgets/context_ring.dart';
import 'package:wing/core/widgets/composer_action_button.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/models/composer_action.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/profile_intelligence_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFormFamilyFonts);
  const capture = bool.fromEnvironment('CAPTURE_INTELLIGENCE');
  setUpAll(() async {
    if (!capture) return;
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'Ahem': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
    }.entries) {
      final bytes = File(entry.value).readAsBytesSync();
      await (FontLoader(
        entry.key,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
  });
  late ProfileIntelligenceFixture host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late SharedPreferences prefs;
  Future<ProfileWorkspaceController> open() async {
    final c = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'picker-test',
      preferences: prefs,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    addTearDown(c.dispose);
    await c.initialize();
    await c.createChat(canDispatch: () => true);
    return c;
  }

  const selection = ChatIntelligenceSelection(
    choice: ModelChoice(provider: 'openai-codex', model: 'gpt-5.6-sol'),
    reasoningEffort: 'xhigh',
    fastMode: ChatFastMode.normal,
  );
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(prefs);
    addTearDown(appPreferences.dispose);
    host = ProfileIntelligenceFixture();
    controller = await open();
  });

  test(
    'context pin follows full stats and survives sparse usage only',
    () async {
      final chat = controller.current!.chat!;
      host.contextResponse = Completer()
        ..complete({
          'context_used': 10,
          'context_max': 100,
          'context_percent': 10,
        });
      host.contextStats = {
        'context_tokens': 30,
        'context_length': 200,
        'config_context_length': 200,
        'context_source': 'provider_usage',
      };
      await controller.refreshContext(chat);
      expect(chat.context!.max, 200);
      expect(chat.context!.used, 30);
      expect(chat.context!.pinned, isTrue);
      emitChatEvent(controller, chat, 'session.usage', {
        'usage': {'context_used': 40, 'context_percent': 20},
      });
      expect(chat.context!.configuredMax, 200);
      host.contextStats = {};
      await controller.refreshContext(chat);
      expect(chat.context!.configuredMax, isNull);
    },
  );

  test(
    'profile default reset sends only reset and adopts observed session model',
    () async {
      final chat = controller.current!.chat!;
      await controller.setIntelligence(
        chat,
        const ChatIntelligenceSelection(
          choice: ModelChoice(
            provider: 'ignored-provider',
            model: 'ignored-model',
          ),
          reasoningEffort: 'high',
          fastMode: ChatFastMode.fast,
          useProfileDefault: true,
        ),
        confirmModelChange: (_) async =>
            throw StateError('Reset cannot ask for model confirmation'),
      );
      expect(host.writes, hasLength(1));
      expect(host.writes.single['operation'], 'model');
      expect(host.writes.single['payload'], {'model': 'reset'});
      expect(chat.model, 'gpt-6-astra');
      expect(chat.reasoningEffort, 'high');
      expect(chat.fastMode, ChatFastMode.normal);
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('profile reset menu holds feedback $brightness $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          RepaintBoundary(
            key: formFamilyCapture,
            child: MaterialApp(
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
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('chat-intelligence-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('More model options'));
        await tester.pumpAndSettle();
        expect(find.text('Use profile default'), findsOneWidget);
        await captureFormFamily(
          tester,
          'model-reset-menu-${brightness.name}-$scale',
        );
        final held = Completer<void>();
        host.configSetDelay = held;
        await tester.tap(find.text('Use profile default'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(CircularProgressIndicator), findsWidgets);
        await captureFormFamily(
          tester,
          'model-reset-pending-${brightness.name}-$scale',
        );
        held.complete();
        await tester.pumpAndSettle();
        expect(host.writes.single['payload'], {'model': 'reset'});
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  for (final brightness in Brightness.values) {
    for (final (size, scale) in [
      (const Size(390, 844), 1.0),
      (const Size(320, 640), 2.0),
    ]) {
      testWidgets('Fast retains context and reports held writes '
          '$brightness $size at text $scale', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final chat = controller.current!.chat!;
        chat.composer.editText('Keep this draft');
        emitChatEvent(controller, chat, 'session.usage', {
          'usage': {
            'context_used': 360,
            'context_max': 1000,
            'context_percent': 36,
          },
        });
        const frame = Key('fast-context-preview');
        await tester.pumpWidget(
          RepaintBoundary(
            key: frame,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: scale == 2,
                ),
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
        final ring = find.byType(ContextRing);
        final fast = find.byKey(const Key('composer-fast-control'));
        final send = find.byType(ComposerActionButton);
        final ringRect = tester.getRect(ring);
        final sendRect = tester.getRect(send);
        final headerRect = tester.getRect(
          find.byKey(const ValueKey('studio-loading-slot')),
        );
        expect(tester.widget<ContextRing>(ring).occupancy?.percent, 36);
        Future<void> screenshot(String state) async {
          if (!capture) return;
          await tester.runAsync(() async {
            final image = await tester
                .renderObject<RenderRepaintBoundary>(find.byKey(frame))
                .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final directory = Directory('build/design-previews/fast-context');
            await directory.create(recursive: true);
            await File(
              '${directory.path}/${brightness.name}-'
              '${size.width.toInt()}-$state.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        await screenshot('ready');
        host.onAcceptedWrite = (params) {
          // Stock config.set fast emits session.info before acknowledging.
          emitChatEvent(controller, chat, 'session.info', {
            'model': chat.model,
            'provider': chat.provider,
            'reasoning_effort': chat.reasoningEffort,
          });
        };
        for (final fails in [true, false]) {
          host.failFast = fails;
          host.configSetDelay = Completer<void>();
          host.contextResponse = Completer<Map<String, dynamic>>();
          final heldWrite = host.configSetDelay!;
          final heldContext = host.contextResponse!;
          addTearDown(() {
            if (!heldWrite.isCompleted) heldWrite.complete();
            if (!heldContext.isCompleted) heldContext.complete({});
          });
          await tester.tap(fast);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(chat.changingIntelligence, isTrue);
          expect(tester.widget<ContextRing>(ring).occupancy?.percent, 36);
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(
            tester.widget<StudioLoading>(find.byType(StudioLoading)).label,
            'Updating model settings',
          );
          expect(tester.getRect(ring), ringRect);
          expect(tester.getRect(send), sendRect);
          expect(
            tester.getRect(find.byKey(const ValueKey('studio-loading-slot'))),
            headerRect,
          );
          expect(
            tester
                .widget<ComposerActionButton>(send)
                .unavailable[ComposerAction.send],
            isNotNull,
          );
          expect(tester.widget<TextButton>(fast).onPressed, isNull);
          expect(host.writes, hasLength(fails ? 1 : 2));
          await tester.enterText(
            find.byType(TextField).first,
            'Draft edited while switching',
          );
          await screenshot(fails ? 'held-failure' : 'held-success');
          heldWrite.complete();
          await tester.pumpAndSettle();
          expect(chat.changingIntelligence, isFalse);
          expect(
            chat.fastMode,
            fails ? ChatFastMode.normal : ChatFastMode.fast,
          );
          expect(chat.contextLoading, !fails);
          expect(tester.widget<ContextRing>(ring).occupancy?.percent, 36);
          expect(find.byType(StudioLoading), findsNothing);
          expect(
            tester
                .widget<ComposerActionButton>(send)
                .unavailable[ComposerAction.send],
            isNull,
          );
          expect(tester.getRect(ring), ringRect);
          expect(tester.getRect(send), sendRect);
          expect(
            chat.composer.observation.text,
            'Draft edited while switching',
          );
          if (fails) {
            expect(
              find.text('Fast mode could not be confirmed. Try again.'),
              findsOneWidget,
            );
          }
          await screenshot(fails ? 'failed' : 'complete');
          expect(tester.takeException(), isNull);
          if (fails) {
            await tester.pump(const Duration(seconds: 5));
            await tester.pumpAndSettle();
          }
        }
        final refresh = controller.refreshContext(chat);
        host.contextResponse!.complete({
          'context_used': 400,
          'context_max': 1000,
          'context_percent': 40,
        });
        await refresh;
        await tester.pumpAndSettle();
        expect(tester.widget<ContextRing>(ring).occupancy?.percent, 40);
      });
    }
  }

  for (final change in ['fast', 'reasoning', 'model', 'provider']) {
    test(
      '$change settings invalidate context only for a different route',
      () async {
        final chat = controller.current!.chat!;
        await controller.loadIntelligence(chat);
        emitChatEvent(controller, chat, 'session.usage', {
          'usage': {
            'context_used': 360,
            'context_max': 1000,
            'context_percent': 36,
          },
        });
        host.contextResponse = Completer<Map<String, dynamic>>();
        addTearDown(() {
          if (!host.contextResponse!.isCompleted) {
            host.contextResponse!.complete({});
          }
        });
        await controller.setIntelligence(
          chat,
          ChatIntelligenceSelection(
            choice: ModelChoice(
              provider: change == 'provider' ? 'openrouter' : chat.provider!,
              model: change == 'model' ? 'gpt-5.6-sol' : chat.model!,
            ),
            reasoningEffort: change == 'reasoning'
                ? 'low'
                : chat.reasoningEffort!,
            fastMode: change == 'fast' ? ChatFastMode.fast : chat.fastMode!,
          ),
          confirmModelChange: (_) async => fail('Unexpected confirmation'),
        );
        final routeChanged = change == 'model' || change == 'provider';
        expect(chat.contextLoading, routeChanged);
        expect(chat.context?.percent, routeChanged ? null : 36);
      },
    );
  }

  test(
    'selection writes the session and reopen uses server settings',
    () async {
      final chat = controller.current!.chat!;
      final intelligence = await controller.loadIntelligence(chat);
      expect(intelligence.choices.first.providerLabel, 'OpenAI subscription');
      await controller.setIntelligence(
        chat,
        selection,
        confirmModelChange: (_) async => fail('Unexpected confirmation'),
      );
      expect(host.writes, hasLength(1));
      expect(host.writes.single['operation'], 'model');
      expect(host.writes.single['payload'], {
        'model': 'gpt-5.6-sol',
        'provider': 'openai-codex',
        'reasoning': 'xhigh',
      });
      expect(
        host.writes.every(
          (p) => p['profile'] == 'personal' && p['session_id'] == 'runtime',
        ),
        isTrue,
      );
      final reopened = await open();
      final restored = reopened.current!.chat!;
      expect(restored.model, 'gpt-6-astra');
      expect(restored.reasoningEffort, 'high');
      restored.composer.editText('Verify settings');
      await reopened.send(restored);
      expect(host.writes, hasLength(1));
      await reopened.switchProfile('work');
      final other = await reopened.createChat(canDispatch: () => true);
      expect(other.model, 'gpt-6-astra');
      expect(other.reasoningEffort, 'high');
    },
  );

  for (final replacesRuntime in [false, true]) {
    test('a delayed intelligence read cannot overwrite newer hydration '
        '(runtime replaced: $replacesRuntime)', () async {
      final chat = controller.current!.chat!;
      final configStarted = Completer<void>();
      final configDelay = Completer<void>();
      host
        ..configGetStarted = configStarted
        ..configGetDelay = configDelay
        ..resumedRuntimeId = replacesRuntime ? 'replacement-runtime' : null
        ..resumedReasoningEffort = 'low';
      var notifications = 0;
      void countNotifications() => notifications++;

      controller.addListener(countNotifications);
      addTearDown(() => controller.removeListener(countNotifications));
      addTearDown(() {
        if (!configDelay.isCompleted) configDelay.complete();
      });

      final originalRuntime = chat.runtime.runtimeId;
      final pendingLoad = controller.loadIntelligence(chat);
      await configStarted.future;
      if (replacesRuntime) {
        await controller.reconnect(chat.key.workspace);
      } else {
        emitChatEvent(controller, chat, 'session.info', {
          'reasoning_effort': 'low',
        });
      }
      expect(
        chat.runtime.runtimeId,
        replacesRuntime ? 'replacement-runtime' : originalRuntime,
      );
      expect(chat.reasoningEffort, 'low');
      await Future<void>.delayed(Duration.zero);
      final notificationsAfterHydration = notifications;
      configDelay.complete();
      await expectLater(pendingLoad, throwsA(isA<StateError>()));

      expect(chat.reasoningEffort, 'low');
      expect(notifications, notificationsAfterHydration);
    });
  }

  test('a newer intelligence load supersedes an older held load', () async {
    final chat = controller.current!.chat!;
    final configStarted = Completer<void>();
    final configDelay = Completer<void>();
    host
      ..configGetStarted = configStarted
      ..configGetDelay = configDelay
      ..configGetValue = 'medium';
    addTearDown(() {
      if (!configDelay.isCompleted) configDelay.complete();
    });

    final olderLoad = controller.loadIntelligence(chat);
    await configStarted.future;
    final newerLoad = controller.loadIntelligence(chat);
    await Future<void>.delayed(Duration.zero);
    configDelay.complete();
    await expectLater(olderLoad, throwsA(isA<StateError>()));
    await newerLoad;

    expect(chat.reasoningEffort, 'medium');
  });

  test(
    'declining a model confirmation preserves the current settings',
    () async {
      final chat = controller.current!.chat!;
      host.confirmModel = true;
      await controller.setIntelligence(
        chat,
        selection,
        confirmModelChange: (_) async => false,
      );
      expect(host.writes, hasLength(1));
      expect(chat.model, 'gpt-6-astra');
      expect(chat.changingIntelligence, isFalse);
    },
  );

  test(
    'rejected atomic model and reasoning change preserves both previous values',
    () async {
      final chat = controller.current!.chat!;
      host.failReasoning = true;
      await expectLater(
        controller.setIntelligence(
          chat,
          selection,
          confirmModelChange: (_) async => fail('Unexpected confirmation'),
        ),
        throwsStateError,
      );
      expect(host.writes, hasLength(1));
      expect(chat.model, 'gpt-6-astra');
      expect(chat.reasoningEffort, 'high');
      expect(chat.changingIntelligence, isFalse);
    },
  );

  test(
    'model info emitted before its acknowledgement is accepted for the owned route',
    () async {
      final chat = controller.current!.chat!;
      host.onAcceptedWrite = (params) {
        if (params['operation'] == 'model') {
          emitChatEvent(controller, chat, 'session.info', {
            'model': selection.choice.model,
            'provider': selection.choice.provider,
          });
        }
      };
      expect(
        await controller.setIntelligence(
          chat,
          selection,
          confirmModelChange: (_) async => true,
        ),
        isTrue,
      );
      expect(chat.model, selection.choice.model);
      expect(chat.reasoningEffort, selection.reasoningEffort);
    },
  );

  test(
    'fast changes are session owned; a failed fast save retries only fast',
    () async {
      final chat = controller.current!.chat!;
      await controller.loadIntelligence(chat);
      final chosen = ChatIntelligenceSelection(
        choice: selection.choice,
        reasoningEffort: selection.reasoningEffort,
        fastMode: ChatFastMode.fast,
      );
      host.failFast = true;
      await expectLater(
        controller.setIntelligence(
          chat,
          chosen,
          confirmModelChange: (_) async => true,
        ),
        throwsStateError,
      );
      expect(chat.model, selection.choice.model);
      expect(chat.reasoningEffort, 'xhigh');
      expect(chat.fastMode, ChatFastMode.normal);
      expect(host.writes.map((w) => w['operation'] ?? w['key']), [
        'model',
        'fast',
      ]);
      host.failFast = false;
      await controller.setIntelligence(
        chat,
        chosen,
        confirmModelChange: (_) async => fail('Unexpected confirmation'),
      );
      expect(host.writes.map((w) => w['operation'] ?? w['key']), [
        'model',
        'fast',
        'fast',
      ]);
      expect(host.writes.last['session_id'], 'runtime');
      expect(host.writes.last['profile'], 'personal');
      expect(chat.fastMode, ChatFastMode.fast);
    },
  );
  test('ultrafast survives an unchanged Apply without a write', () async {
    host.fastMode = 'ultrafast';
    final chat = controller.current!.chat!;
    final options = await controller.loadIntelligence(chat);
    final current = options.choices.first;
    await controller.setIntelligence(
      chat,
      ChatIntelligenceSelection(
        choice: current,
        reasoningEffort: chat.reasoningEffort!,
        fastMode: chat.fastMode!,
      ),
      confirmModelChange: (_) async => true,
    );
    expect(host.writes, isEmpty);
    expect(chat.fastMode, ChatFastMode.ultrafast);
  });

  test('turning ultrafast off writes normal mode', () async {
    host.fastMode = 'ultrafast';
    final chat = controller.current!.chat!;
    final options = await controller.loadIntelligence(chat);
    final current = options.choices.first;
    await controller.setIntelligence(
      chat,
      ChatIntelligenceSelection(
        choice: current,
        reasoningEffort: chat.reasoningEffort!,
        fastMode: ChatFastMode.normal,
      ),
      confirmModelChange: (_) async => true,
    );
    expect(host.writes.single['key'], 'fast');
    expect(host.writes.single['value'], 'normal');
  });

  for (final staleChange in ['runtime', 'model', 'provider', 'profile']) {
    test('confirmation cannot apply after $staleChange changes', () async {
      host.confirmModel = true;
      final chat = controller.current!.chat!;
      await expectLater(
        controller.setIntelligence(
          chat,
          selection,
          confirmModelChange: (_) async {
            switch (staleChange) {
              case 'runtime':
                host.resumedRuntimeId = 'replacement';
                await controller.reconnect(chat.key.workspace);
              case 'model':
                host.repeatConfirmation = true;
                emitChatEvent(controller, chat, 'session.info', {
                  'model': 'gpt-5.4-mini',
                });
              case 'provider':
                host.repeatConfirmation = true;
                emitChatEvent(controller, chat, 'session.info', {
                  'provider': 'other-provider',
                });
              case 'profile':
                await controller.switchProfile('work');
            }
            return true;
          },
        ),
        throwsStateError,
      );
      expect(
        host.writes,
        hasLength(staleChange == 'model' || staleChange == 'provider' ? 2 : 1),
      );
      expect(chat.reasoningEffort, 'high');
      expect(chat.changingIntelligence, isFalse);
    });
  }

  test(
    'a busy model choice remains pending until server hydration confirms it',
    () async {
      final chat = controller.current!.chat!;
      await controller.loadIntelligence(chat);
      host.deferMutation = true;
      emitChatEvent(controller, chat, 'message.start');
      expect(
        await controller.setIntelligence(
          chat,
          selection,
          confirmModelChange: (_) async => fail('Unexpected confirmation'),
        ),
        isTrue,
      );
      expect(host.writes, hasLength(1));
      expect(chat.model, 'gpt-6-astra');
      expect(chat.reasoningEffort, 'high');
      expect(chat.pendingIntelligence, selection);
      emitChatEvent(controller, chat, 'session.updated', {
        'model': selection.choice.model,
        'provider': selection.choice.provider,
        'effort': selection.reasoningEffort,
      });
      expect(chat.model, selection.choice.model);
      expect(chat.reasoningEffort, selection.reasoningEffort);
      expect(chat.pendingIntelligence, isNull);
    },
  );

  for (final changeRoute in [false, true]) {
    test(
      'returning to the effective ${changeRoute ? 'model' : 'reasoning'} supersedes a deferred choice',
      () async {
        final chat = controller.current!.chat!;
        await controller.loadIntelligence(chat);
        final effective = ChatIntelligenceSelection(
          choice: ModelChoice(provider: chat.provider!, model: chat.model!),
          reasoningEffort: chat.reasoningEffort!,
          fastMode: chat.fastMode!,
        );
        host.deferMutation = true;
        emitChatEvent(controller, chat, 'message.start');
        final pending = changeRoute
            ? selection
            : ChatIntelligenceSelection(
                choice: effective.choice,
                reasoningEffort: 'low',
                fastMode: effective.fastMode,
              );
        await controller.setIntelligence(
          chat,
          pending,
          confirmModelChange: (_) async => false,
        );
        expect(chat.pendingIntelligence, pending);
        await controller.setIntelligence(
          chat,
          effective,
          confirmModelChange: (_) async => false,
        );
        expect(host.writes, hasLength(2));
        expect(
          host.writes.last['operation'],
          changeRoute ? 'model' : 'reasoning',
        );
        expect(
          host.writes.last['payload'],
          changeRoute
              ? {
                  'model': effective.choice.model,
                  'provider': effective.choice.provider,
                  'reasoning': effective.reasoningEffort,
                }
              : {'effort': effective.reasoningEffort},
        );
        expect(chat.pendingIntelligence, effective);
        expect(chat.model, effective.choice.model);
        expect(chat.reasoningEffort, effective.reasoningEffort);
      },
    );
  }

  for (final repeatedGuard in [false, true]) {
    test(
      'confirmed failure does not retry (repeated guard: $repeatedGuard)',
      () async {
        host
          ..confirmModel = true
          ..repeatConfirmation = repeatedGuard
          ..failConfirmedModel = !repeatedGuard;
        final chat = controller.current!.chat!;
        var confirmations = 0;
        await expectLater(
          controller.setIntelligence(
            chat,
            selection,
            confirmModelChange: (message) async {
              expect(message, ProfileIntelligenceFixture.modelWarning);
              confirmations++;
              return true;
            },
          ),
          throwsStateError,
        );
        expect(confirmations, 1);
        expect(host.writes, hasLength(2));
        expect(chat.model, 'gpt-6-astra');
        expect(chat.reasoningEffort, 'high');
        expect(chat.changingIntelligence, isFalse);
      },
    );
  }

  test('pending confirmation blocks duplicate switches and sending', () async {
    host.confirmModel = true;
    final chat = controller.current!.chat!;
    final decision = Completer<bool>();
    final requested = Completer<void>();
    final applying = controller.setIntelligence(
      chat,
      selection,
      confirmModelChange: (_) {
        requested.complete();
        return decision.future;
      },
    );
    await requested.future;
    expect(chat.changingIntelligence, isTrue);
    await expectLater(
      controller.setIntelligence(
        chat,
        selection,
        confirmModelChange: (_) async => fail('Duplicate confirmation'),
      ),
      throwsStateError,
    );
    chat.composer.editText('Keep this draft');
    await controller.send(chat);
    expect(chat.composer.observation.text, 'Keep this draft');
    expect(host.writes, hasLength(1));
    decision.complete(false);
    await applying;
    expect(chat.changingIntelligence, isFalse);
  });

  testWidgets(
    'large-context model switch offers a confirmation before applying',
    (tester) async {
      host.confirmModel = true;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileWorkspaceScreen(
            controller: controller,
            createBotsSession: () => BotsSession((_) async => const []),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat-intelligence-button')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('model-search')), 'sol');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('model-openai-codex-gpt-5.6-sol')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Apply model settings'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('Confirm model change'), findsOneWidget);
      expect(
        find.text(ProfileIntelligenceFixture.modelWarning),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byTooltip('Cancel'),
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('Switch model'), findsOneWidget);
      expect(host.writes, hasLength(1));
      expect(controller.current!.chat!.model, 'gpt-6-astra');
      await tester.tap(find.byTooltip('Switch model'));
      await tester.pumpAndSettle();
      expect(host.writes, hasLength(2));
      expect(host.writes.last['operation'], 'model');
      expect(host.writes.last['payload'], {
        ...host.writes.first['payload'] as Map,
        'confirm': 'fixture-model-confirmation',
      });
      expect(host.writes.last['session_id'], host.writes.first['session_id']);
      expect(controller.current!.chat!.model, 'gpt-5.6-sol');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'retrying a rejected atomic model save preserves and reapplies both choices',
    (tester) async {
      host.failReasoning = true;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileWorkspaceScreen(
            controller: controller,
            createBotsSession: () => BotsSession((_) async => const []),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat-intelligence-button')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('model-search')), 'sol');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('model-openai-codex-gpt-5.6-sol')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Apply model settings'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Reasoning rejected'), findsOneWidget);
      expect(find.text('Models'), findsOneWidget);
      expect(host.writes, hasLength(1));
      expect(controller.current!.chat!.model, 'gpt-6-astra');
      expect(controller.current!.chat!.reasoningEffort, 'high');
      host.failReasoning = false;
      await tester.tap(find.byTooltip('Apply model settings'));
      await tester.pumpAndSettle();
      expect(host.writes, hasLength(2));
      expect(host.writes.last['operation'], 'model');
      expect(host.writes.last['payload'], host.writes.first['payload']);
      expect(controller.current!.chat!.model, 'gpt-5.6-sol');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the shipped profile composer opens picker and applies both choices',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileWorkspaceScreen(
            controller: controller,
            createBotsSession: () => BotsSession((_) async => const []),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat-intelligence-button')));
      await tester.pumpAndSettle();
      expect(find.text('Models'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('model-search')), 'sol');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('model-openai-codex-gpt-5.6-sol')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat-reasoning-control')).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reasoning-xhigh')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Apply model settings'));
      await tester.pumpAndSettle();
      expect(find.text('5.6 Sol'), findsOneWidget);
      expect(controller.current!.chat!.reasoningEffort, 'xhigh');
      expect(host.writes, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('model picker refreshes the current profile and reveals Codex', (
    tester,
  ) async {
    host.codexAppearsOnRefresh = true;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-intelligence-button')));
    await tester.pumpAndSettle();
    expect(find.text('OpenAI subscription'), findsNothing);

    await tester.tap(find.byKey(const Key('refresh-chat-models')));
    await tester.pumpAndSettle();

    expect(
      host.modelOptionReads.every((q) => q['profile'] == 'personal'),
      isTrue,
    );
    expect(host.modelOptionReads.last, {'profile': 'personal', 'refresh': '1'});
    expect(find.text('OpenAI subscription'), findsWidgets);
    expect(
      find.byKey(const Key('review-model-provider-access')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('model-openai-codex-gpt-5.6-sol')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'reopening uses the chat route rather than the profile default or first provider',
    (tester) async {
      host.mixedCatalog = true;
      final chat = controller.current!.chat!;
      emitChatEvent(controller, chat, 'session.info', {
        'model': 'gpt-6.1-sol',
        'provider': 'openai-codex',
      });
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: ProfileWorkspaceScreen(
            controller: controller,
            createBotsSession: () => BotsSession((_) async => const []),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (var opening = 0; opening < 2; opening++) {
        await tester.tap(find.byKey(const Key('chat-intelligence-button')));
        await tester.pumpAndSettle();
        final semantics = tester.ensureSemantics();
        final tab = find.byKey(const Key('model-filter-openai-codex'));
        final row = find.byKey(const Key('model-openai-codex-gpt-6.1-sol'));
        expect(tab.hitTestable(), findsOneWidget);
        expect(row.hitTestable(), findsOneWidget);
        expect(tester.getSemantics(tab), isSemantics(isSelected: true));
        expect(tester.getSemantics(row), isSemantics(isSelected: true));
        semantics.dispose();
        expect(
          find.byKey(const Key('model-openrouter-gpt-6.1-sol')),
          findsNothing,
        );
        await tester.tap(find.byTooltip('Apply model settings'));
        await tester.pumpAndSettle();
        expect(chat.model, 'gpt-6.1-sol');
        expect(chat.provider, 'openai-codex');
        expect(host.writes, isEmpty);
      }
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('changing chats retires held reasoning without a write', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final held = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('composer-reasoning-control'))),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await held.moveTo(
      tester.getCenter(find.byKey(const Key('composer-reasoning-choice-low'))),
    );
    await tester.pump();
    final previous = controller.current!.chat!.key;
    await controller.createChat(canDispatch: () => true);
    expect(controller.current!.chat!.key, isNot(previous));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('composer-reasoning-selector')), findsNothing);
    await held.up();
    await tester.pumpAndSettle();
    expect(host.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    for (final (size, scale) in [
      (const Size(390, 844), 1.0),
      (const Size(320, 640), 2.0),
    ]) {
      for (final interaction in [
        'fit',
        'outside dismissal',
        'held cancellation',
        'held selection',
        'tap selection',
        'fast toggle',
        'picker cancellation',
        'keyboard escape',
        'keyboard back',
      ]) {
        testWidgets('composer $interaction at $brightness $size text $scale', (
          tester,
        ) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
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
          );
          await tester.pumpAndSettle();
          final indicator = find.byKey(const Key('chat-intelligence-button'));
          final thinking = find.byKey(const Key('composer-reasoning-control'));
          final lightning = find.byKey(const Key('composer-fast-control'));
          final selector = find.byKey(const Key('composer-reasoning-selector'));
          final chat = controller.current!.chat!;
          switch (interaction) {
            case 'fit':
              final viewport = Offset.zero & size;
              final controls = [indicator, thinking, lightning];
              for (final control in controls) {
                expect(control.hitTestable(), findsOneWidget);
                final bounds = tester.getRect(control);
                expect(viewport.intersect(bounds), bounds);
              }
              for (var i = 0; i < controls.length; i++) {
                for (var j = i + 1; j < controls.length; j++) {
                  expect(
                    tester
                        .getRect(controls[i])
                        .overlaps(tester.getRect(controls[j])),
                    isFalse,
                  );
                }
              }
            case 'outside dismissal':
              await tester.tap(thinking);
              await tester.pumpAndSettle();
              expect(selector, findsOneWidget);
              await tester.tapAt(const Offset(2, 2));
              await tester.pumpAndSettle();
              expect(selector, findsNothing);
              expect(host.writes, isEmpty);
            case 'held cancellation':
              final held = await tester.startGesture(
                tester.getCenter(thinking),
              );
              await tester.pump(const Duration(milliseconds: 600));
              expect(selector, findsOneWidget);
              await held.moveTo(const Offset(2, 2));
              await held.up();
              await tester.pumpAndSettle();
              expect(selector, findsNothing);
              expect(host.writes, isEmpty);
            case 'held selection':
              final held = await tester.startGesture(
                tester.getCenter(thinking),
              );
              await tester.pump(const Duration(milliseconds: 600));
              await held.moveTo(
                tester.getCenter(
                  find.byKey(const Key('composer-reasoning-choice-low')),
                ),
              );
              await tester.pump();
              expect(host.writes, isEmpty);
              await held.up();
              await tester.pumpAndSettle();
              expect(host.writes.single['operation'], 'reasoning');
              expect(host.writes.single['payload'], {'effort': 'low'});
              expect(chat.reasoningEffort, 'low');
            case 'tap selection':
              await tester.tap(thinking);
              await tester.pumpAndSettle();
              await tester.tap(
                find.byKey(const Key('composer-reasoning-choice-low')),
              );
              await tester.pumpAndSettle();
              expect(host.writes.single['operation'], 'reasoning');
              expect(host.writes.single['payload'], {'effort': 'low'});
              expect(chat.reasoningEffort, 'low');
            case 'fast toggle':
              await tester.tap(lightning);
              await tester.pumpAndSettle();
              expect(host.writes.single['key'], 'fast');
              expect(host.writes.single['value'], 'fast');
              expect(chat.fastMode, ChatFastMode.fast);
            case 'picker cancellation':
              await tester.tap(indicator);
              await tester.pumpAndSettle();
              expect(find.text('Models'), findsOneWidget);
              await tester.tap(find.byKey(const Key('chat-fast-control')));
              await tester.pumpAndSettle();
              expect(host.writes, isEmpty);
              await tester.tap(find.byTooltip('Close'));
              await tester.pumpAndSettle();
              expect(host.writes, isEmpty);
              expect(chat.fastMode, ChatFastMode.normal);
            case 'keyboard escape':
            case 'keyboard back':
              if (scale == 2) tester.view.physicalSize = Size(size.width, 844);
              final draft = find.byType(TextField).first;
              await tester.enterText(draft, 'Draft');
              tester.view.viewInsets = const FakeViewPadding(bottom: 260);
              await tester.pumpAndSettle();
              final input = tester.widget<TextField>(draft);
              final composerBounds = tester.getRect(draft);
              expect(input.focusNode!.hasFocus, isTrue);
              await tester.tap(thinking);
              await tester.pumpAndSettle();
              expect(selector, findsOneWidget);
              expect(input.focusNode!.hasFocus, isTrue);
              expect(tester.getRect(draft), composerBounds);
              if (interaction == 'keyboard escape') {
                await tester.sendKeyEvent(LogicalKeyboardKey.escape);
              } else {
                await tester.binding.handlePopRoute();
              }
              await tester.pumpAndSettle();
              expect(selector, findsNothing);
              expect(input.focusNode!.hasFocus, isTrue);
              expect(controller.current!.chat, same(chat));
              expect(chat.composer.observation.text, 'Draft');
              expect(host.writes, isEmpty);
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
