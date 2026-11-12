import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/context_ring.dart';
import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'profile_workspace_controller_test.dart' show Host;

void main() {
  const capture = bool.fromEnvironment('CAPTURE_ACTIVE_CONTEXT');
  setUpAll(() async {
    if (!capture) return;
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'Ahem': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            Future.value(
              ByteData.sublistView(File(entry.value).readAsBytesSync()),
            ),
          ))
          .load();
    }
  });
  late Host host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  Completer<Map<String, dynamic>>? pending;
  late Map<String, dynamic> breakdownResponse;
  const snapshot = {
    'context_used': 250,
    'context_max': 1000,
    'context_percent': 25,
  };
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    host = Host();
    pending = null;
    breakdownResponse = snapshot;
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'context-test',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: (scope) {
        final base = host.gateway(scope);
        late final ProfileGateway gateway;
        gateway = ProfileGateway(
          scope: scope,
          discover: base.discover,
          connect: () async {
            if (gateway.onEvent != null) {
              host.gateways[scope.profileName] = gateway;
            }
            await base.connect();
          },
          get: base.read,
          rpc: (method, params) {
            if (method == 'session.context_breakdown') {
              host.calls.add((scope.profileName, method, params));
              return pending?.future ?? Future.value(breakdownResponse);
            }
            return base.call(method, params);
          },
        );
        return gateway;
      },
    );
    await controller.initialize();
  });
  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  test(
    'usage belongs to the original chat and partial events retain server limits',
    () async {
      final a = await controller.createChat(canDispatch: () => true);
      await controller.refreshContext(a);
      expect(a.context!.percent, 25);
      expect(host.calls.last.$3, {'session_id': 'a-runtime', 'profile': 'a'});
      await controller.switchProfile('b');
      final b = await controller.createChat(canDispatch: () => true);
      await controller.refreshContext(b);
      host.event('a', 'session.usage', {
        'usage': {'context_used': 750, 'context_percent': 75},
      });
      expect(a.context!.percent, 75);
      expect(a.context!.max, 1000);
      expect(b.context!.percent, 25);
    },
  );

  test('late breakdown cannot overwrite a newer live usage event', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    await controller.refreshContext(chat);
    pending = Completer();
    final refresh = controller.refreshContext(chat);
    host.event('a', 'session.usage', {
      'usage': {'context_used': 900, 'context_percent': 90},
    });
    pending!.complete(snapshot);
    await refresh;
    expect(chat.context!.percent, 90);
    host.event('a', 'session.usage', {
      'usage': {'context_max': 0},
    });
    expect(chat.context, isNull);
  });

  test(
    'refetches context when a resumed session becomes ready without a prompt',
    () async {
      // A cold resume can answer context_breakdown before the lazy agent exists.
      // Hermes returns an explicit zero/unknown breakdown in that phase, then
      // emits session.info after agent construction. The ready response has no
      // context_* fields until the next breakdown RPC.
      breakdownResponse = {
        'context_used': 0,
        'context_max': 0,
        'context_percent': 0,
        'context_estimated': false,
      };
      host.running = false;
      await controller.openSession(
        ProfileSessionKey(controller.current!.scope, 'same'),
      );
      final restored = controller.current!.chat!;
      await Future<void>.delayed(Duration.zero);
      expect(restored.context, isNull);
      expect(
        host.calls.where((call) => call.$2 == 'session.context_breakdown'),
        hasLength(1),
      );

      breakdownResponse = {
        'context_used': 1200,
        'context_max': 4000,
        'context_percent': 30,
        'context_estimated': true,
      };
      host.event('a', 'session.info', {
        'usage': {'calls': 0, 'input': 0, 'output': 0, 'total': 0},
      });
      await Future<void>.delayed(Duration.zero);

      expect(restored.context?.percent, 30);
      expect(restored.context?.estimated, isTrue);
      expect(restored.reading.messages, isNotEmpty);
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
      expect(
        host.calls.where((call) => call.$2 == 'session.context_breakdown'),
        hasLength(2),
      );
    },
  );

  test(
    'late pre-ready breakdown cannot erase the ready session usage',
    () async {
      host.running = false;
      final beforeReady = Completer<Map<String, dynamic>>();
      pending = beforeReady;
      await controller.openSession(
        ProfileSessionKey(controller.current!.scope, 'same'),
      );
      final chat = controller.current!.chat!;
      pending = null;
      host.event('a', 'session.info', {
        'usage': {'calls': 0, 'input': 0, 'output': 0},
      });
      await Future<void>.delayed(Duration.zero);
      expect(chat.context?.percent, 25);
      beforeReady.complete({
        'context_used': 0,
        'context_max': 0,
        'context_percent': 0,
      });
      await Future<void>.delayed(Duration.zero);
      expect(chat.context?.percent, 25);
    },
  );
  test('composition is chat-owned and survives live usage updates', () async {
    breakdownResponse = {
      ...snapshot,
      'categories': [
        {'id': 'conversation', 'label': 'Conversation', 'tokens': 200},
      ],
    };
    final a = await controller.createChat(canDispatch: () => true);
    await controller.refreshContext(a);
    await controller.switchProfile('b');
    final b = await controller.createChat(canDispatch: () => true);
    await controller.refreshContext(b);
    host.event('a', 'session.usage', {
      'usage': {'context_used': 750, 'context_percent': 75, 'compressions': 2},
    });
    expect(a.context!.used, 750);
    expect(a.context!.categories.single.tokens, 200);
    expect(a.contextCompressions, 2);
    expect(b.context!.categories.single.tokens, 200);
    expect(b.contextCompressions, isNull);
  });

  test('a new turn retains composition and a pending breakdown', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    await controller.refreshContext(chat);
    pending = Completer();
    final refresh = controller.refreshContext(chat);
    expect(chat.contextLoading, isTrue);
    host.event('a', 'message.start', {});
    expect(chat.contextLoading, isTrue);
    pending!.complete({
      ...snapshot,
      'categories': [
        {'id': 'conversation', 'label': 'Conversation', 'tokens': 200},
      ],
    });
    await refresh;
    expect(chat.context!.categories.single.tokens, 200);
    expect(chat.contextLoading, isFalse);
  });

  test('active turns admit breakdown reads and retry after failure', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    host.event('a', 'message.start', {});
    expect(chat.runtime.blocksTurnAdmission, isTrue);
    pending = Completer();
    final refresh = controller.refreshContext(chat);
    expect(chat.contextLoading, isTrue);
    pending!.completeError(StateError('fixture failure'));
    await refresh;
    expect(chat.contextError, isNotNull);
    pending = null;
    breakdownResponse = {
      ...snapshot,
      'categories': [
        {'id': 'conversation', 'label': 'Conversation', 'tokens': 200},
      ],
    };
    await controller.refreshContext(chat);
    expect(chat.contextError, isNull);
    expect(chat.context!.categories.single.tokens, 200);
    expect(chat.runtime.blocksTurnAdmission, isTrue);
  });

  test(
    'live totals do not cancel a held breakdown or erase its categories',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      await controller.refreshContext(chat);
      host.event('a', 'message.start', {});
      pending = Completer();
      final refresh = controller.refreshContext(chat);
      host.event('a', 'session.usage', {
        'usage': {'context_used': 900, 'context_percent': 90},
      });
      expect(chat.contextLoading, isTrue);
      pending!.complete({
        ...snapshot,
        'categories': [
          {'id': 'conversation', 'label': 'Conversation', 'tokens': 200},
        ],
      });
      await refresh;
      expect(chat.context!.used, 900);
      expect(chat.context!.percent, 90);
      expect(chat.context!.categories.single.tokens, 200);
      host.event('a', 'session.usage', {
        'usage': {'context_used': 950, 'context_percent': 95},
      });
      expect(chat.context!.categories.single.tokens, 200);
      expect(chat.context!.percent, 95);
    },
  );

  test('compression-only usage refetches composition during a turn', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    host.event('a', 'message.start', {});
    host.event('a', 'session.usage', {
      'usage': {'compressions': 0},
    });
    breakdownResponse = {
      ...snapshot,
      'categories': [
        {'id': 'conversation', 'label': 'Conversation', 'tokens': 200},
      ],
    };
    await controller.refreshContext(chat);
    final before = host.calls
        .where((call) => call.$2 == 'session.context_breakdown')
        .length;
    breakdownResponse = {
      ...snapshot,
      'categories': [
        {'id': 'conversation', 'label': 'Conversation', 'tokens': 40},
      ],
    };
    host.event('a', 'session.usage', {
      'usage': {'compressions': 1},
    });
    expect(chat.context!.categories, isEmpty);
    expect(chat.contextLoading, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(chat.context!.categories.single.tokens, 40);
    expect(chat.contextCompressions, 1);
    expect(chat.runtime.blocksTurnAdmission, isTrue);
    expect(
      host.calls.where((call) => call.$2 == 'session.context_breakdown'),
      hasLength(before + 1),
    );
  });

  test('failed composition read has an explicit retry state', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    pending = Completer();
    final refresh = controller.refreshContext(chat);
    expect(chat.contextLoading, isTrue);
    pending!.completeError(StateError('fixture failure'));
    await refresh;
    expect(chat.contextLoading, isFalse);
    expect(chat.context, isNull);
    expect(chat.contextError, 'Couldn’t load the context breakdown.');
    pending = null;
    await controller.refreshContext(chat);
    expect(chat.contextError, isNull);
    expect(chat.context!.used, 250);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('working chat opens, retries and retains context '
          '${brightness.name} at $scale text', (tester) async {
        final size = Size(scale == 1 ? 390 : 320, 844);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        breakdownResponse = {
          ...snapshot,
          'categories': [
            {'id': 'system_prompt', 'label': 'System prompt', 'tokens': 50},
            {'id': 'conversation', 'label': 'Conversation', 'tokens': 200},
          ],
        };
        final chat = await controller.createChat(canDispatch: () => true);
        await controller.refreshContext(chat);
        host.event('a', 'message.start', {});
        const frame = ValueKey('active-context-frame');
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
                createBotsSession: () => BotsSession((_) async => const []),
                controller: controller,
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        Future<void> screenshot(String state) async {
          if (!capture) return;
          await tester.runAsync(() async {
            final image = await tester
                .renderObject<RenderRepaintBoundary>(find.byKey(frame))
                .toImage();
            try {
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final dir = Directory(
                'build/design-previews/active-context/site',
              );
              await dir.create(recursive: true);
              await File(
                '${dir.path}/${brightness.name}-$scale-$state.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }

        final ring = find.byKey(const ValueKey('context-ring-details'));
        final ringRect = tester.getRect(find.byType(ContextRing));
        pending = Completer();
        await tester.tap(ring);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        final panel = find.byKey(const ValueKey('context-usage-popover'));
        final progress = find.descendant(
          of: panel,
          matching: find.byType(CircularProgressIndicator),
        );
        expect(chat.runtime.blocksTurnAdmission, isTrue);
        expect(chat.contextRefreshPending, isTrue);
        expect(find.text('Conversation'), findsOneWidget);
        expect(
          find.text('No composition breakdown available yet.'),
          findsNothing,
        );
        expect(
          find.bySemanticsLabel('Loading context breakdown'),
          findsOneWidget,
        );
        expect(progress, scale == 1 ? findsOneWidget : findsNothing);
        host.event('a', 'session.usage', {
          'usage': {'context_used': 900, 'context_percent': 90},
        });
        await tester.pump();
        expect(find.text('90% full'), findsOneWidget);
        expect(chat.contextRefreshPending, isTrue);
        await tester.enterText(
          find.byType(TextField).first,
          'Draft stays editable',
        );
        await tester.pump();
        expect(chat.composer.observation.text, 'Draft stays editable');
        expect(tester.getRect(find.byType(ContextRing)), ringRect);
        await screenshot('pending');
        pending!.completeError(StateError('fixture failure'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(chat.contextRefreshPending, isFalse);
        expect(find.text('Conversation'), findsOneWidget);
        expect(
          find.text('Couldn’t load the context breakdown.'),
          findsOneWidget,
        );
        await screenshot('failed');
        pending = Completer();
        await tester.tap(find.byTooltip('Retry context breakdown'));
        await tester.pump();
        expect(chat.contextRefreshPending, isTrue);
        expect(
          find.bySemanticsLabel('Loading context breakdown'),
          findsOneWidget,
        );
        await screenshot('retry');
        pending!.complete({
          ...breakdownResponse,
          'context_used': 950,
          'context_percent': 95,
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(chat.contextRefreshPending, isFalse);
        expect(find.text('95% full'), findsOneWidget);
        expect(find.text('Conversation'), findsOneWidget);
        expect(find.text('Couldn’t load the context breakdown.'), findsNothing);
        expect(chat.runtime.blocksTurnAdmission, isTrue);
        await screenshot('complete');

        // An automatic read remains quiet over available content.
        pending = Completer();
        final background = controller.refreshContext(chat);
        await tester.pump();
        expect(chat.contextLoading, isTrue);
        expect(chat.contextRefreshPending, isFalse);
        expect(
          find.bySemanticsLabel('Loading context breakdown'),
          findsNothing,
        );
        expect(find.text('Conversation'), findsOneWidget);
        await tester.tap(find.byTooltip('Close context window'));
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpWidget(const SizedBox.shrink());
        pending!.complete(breakdownResponse);
        await background;
        await tester.pump();
        expect(panel, findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
