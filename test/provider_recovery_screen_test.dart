import 'package:wing/core/models/provider_inventory.dart';
import 'package:wing/core/screens/administration/admin_provider_credentials.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/provider_access.dart';
import 'package:wing/core/models/provider_recovery.dart';
import 'package:wing/core/services/provider_recovery.dart';
import 'package:wing/core/screens/administration/admin_provider_detail.dart';
import 'package:wing/core/screens/administration/provider_recovery_routes.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'support/administration_fixture.dart';
import 'provider_recovery_test.dart' show claude, pool;

void main() {
  const capture = bool.fromEnvironment('CAPTURE_PROVIDER_RECOVERY');
  setUpAll(() async {
    if (!capture) return;
    const root = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final font in {
      'Roboto': 'roboto-regular.ttf',
      'MaterialIcons': 'materialicons-regular.otf',
      'monospace': 'mono.ttf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            File(
              '$root/${font.value}',
            ).readAsBytes().then((bytes) => bytes.buffer.asByteData()),
          ))
          .load();
    }
  });
  late AdministrationFixture fixture;
  late Map<String, dynamic> observation;
  bool offline = false;
  setUp(() {
    fixture = AdministrationFixture('Claw');
    addTearDown(fixture.server.close);
    observation = claude();
    offline = false;
    fixture.override = (method, path, query, body) async {
      if (path == 'profiles') {
        return {
          'profiles': [
            {'name': 'personal'},
          ],
        };
      }
      if (path == 'profiles/active') return {'current': 'personal'};
      if (path == 'providers/oauth') {
        if (offline) throw StateError('Offline');
        return {
          'providers': [observation],
        };
      }
      if (path == 'providers/oauth/openai-codex' && method == 'DELETE') {
        observation = {
          'id': 'openai-codex',
          'flow': 'device_code',
          'status': {'logged_in': false},
        };
        return {'ok': true};
      }
      if (path == 'files' && method == 'GET') {
        return {
          'entries': [
            {
              'name': '.credentials.json',
              'path': '/home/hermes/.claude/.credentials.json',
              'size': 420,
              'mtime': 1,
              'is_directory': false,
            },
          ],
        };
      }
      if (path == 'files' && method == 'DELETE') {
        observation = {
          'id': 'claude-code',
          'flow': 'external',
          'status': {'logged_in': false},
        };
        return {'ok': true};
      }
      throw StateError('Unexpected $method $path');
    };
    fixture.consoleOverride = (_, command, {confirm = false}) async {
      if (command == 'auth list anthropic') return pool;
      observation = claude(expired: false);
      return 'Refreshed';
    };
  });
  Future<void> show(
    WidgetTester tester,
    Widget page, {
    Brightness brightness = Brightness.dark,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: wingTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: RepaintBoundary(key: const ValueKey('capture'), child: child!),
        ),
        home: page,
      ),
    );
    await tester.pumpAndSettle();
  }

  Widget detail() => providerRecoveryPage(
    profile: fixture.server.profile('personal'),
    providerId: observation['id'] as String,
  );
  Future<void> shot(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/provider-recovery-review/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  final scroll = find.byType(Scrollable).first;
  Future<void> reveal(WidgetTester tester, String text) async {
    await tester.scrollUntilVisible(find.text(text), 200, scrollable: scroll);
    await tester.ensureVisible(find.text(text));
    await tester.pumpAndSettle();
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'recovery and deletion stay reachable ${brightness.name} $scale',
        (tester) async {
          await show(tester, detail(), brightness: brightness, scale: scale);
          expect(find.text('Access token expired'), findsOneWidget);
          await shot(tester, '${brightness.name}-${scale.toInt()}-detail');
          await reveal(tester, 'Renew access');
          await tester.tap(find.text('Renew access'));
          await tester.pumpAndSettle();
          expect(find.text('Renew shared sign-in?'), findsOneWidget);
          expect(fixture.consoleRequests.where((r) => r.$3), isEmpty);
          await shot(tester, '${brightness.name}-${scale.toInt()}-confirm');
          await tester.tap(find.byTooltip('Cancel'));
          await tester.pumpAndSettle();
          await reveal(tester, 'Delete saved credentials');
          await tester.tap(find.text('Delete saved credentials'));
          await tester.pumpAndSettle();
          await shot(tester, '${brightness.name}-${scale.toInt()}-file');
          await reveal(tester, 'Check file');
          expect(
            tester
                .widget<OutlinedButton>(
                  find.widgetWithText(OutlinedButton, 'Check file'),
                )
                .onPressed,
            isNull,
          );
          await tester.scrollUntilVisible(
            find.byType(Switch),
            -180,
            scrollable: scroll,
          );
          await tester.ensureVisible(find.byType(Switch));
          await tester.pumpAndSettle();
          await tester.tap(find.byType(Switch));
          await reveal(tester, 'Check file');
          await tester.pumpAndSettle();
          await tester.tap(find.text('Check file'));
          await tester.pumpAndSettle();
          await reveal(tester, 'Delete credentials');
          await shot(tester, '${brightness.name}-${scale.toInt()}-review');
          expect(fixture.requests.every((r) => r.$1 == 'GET'), isTrue);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('renewal asks for shared consent and reports checked status', (
    tester,
  ) async {
    await show(tester, detail());
    await tester.tap(find.text('Renew access'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byTooltip('Renew access'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Renewal completed.'), findsOneWidget);
    expect(fixture.consoleRequests.where((r) => r.$3).single, (
      'personal',
      'auth refresh anthropic 333ccc',
      true,
    ));
  });
  testWidgets('renewal failure retains observation and sign-in action', (
    tester,
  ) async {
    fixture.consoleOverride = (_, _, {confirm = false}) async =>
        throw const ProviderRecoveryFailure(
          'Renewal was not confirmed. Check status.',
        );
    await show(tester, detail());
    await tester.tap(find.text('Renew access'));
    await tester.pumpAndSettle();
    expect(
      find.text('Renewal was not confirmed. Check status.'),
      findsOneWidget,
    );
    expect(find.text('Access token expired'), findsOneWidget);
    expect(find.text('Sign-in options'), findsOneWidget);
    await shot(tester, 'renewal-failed');
  });
  testWidgets('failed check retains last observation and can retry', (
    tester,
  ) async {
    await show(tester, detail());
    offline = true;
    await tester.tap(find.text('Check status'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('The last observation is shown.'),
      findsOneWidget,
    );
    expect(find.text('Access token expired'), findsOneWidget);
    await shot(tester, 'status-failed');
    offline = false;
    await tester.tap(find.text('Check status'));
    await tester.pumpAndSettle();
    expect(find.textContaining('The last observation is shown.'), findsNothing);
  });
  testWidgets(
    'renewal loading disables other actions without duplicate submission',
    (tester) async {
      final gate = Completer<String>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete('anthropic (0 credentials):\n');
      });
      fixture.consoleOverride = (_, _, {confirm = false}) => gate.future;
      await show(tester, detail());
      await tester.tap(find.text('Renew access'));
      await tester.pump();
      final progress = find.descendant(
        of: find.widgetWithText(FilledButton, 'Renew access'),
        matching: find.byType(CircularProgressIndicator),
      );
      expect(progress, findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Sign-in options'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Renew access'));
      await tester.tap(find.text('Sign-in options'));
      await tester.pump(const Duration(seconds: 2));
      expect(progress, findsOneWidget);
      expect(fixture.consoleRequests, hasLength(1));
      await shot(tester, 'renewal-loading');
      gate.complete('anthropic (0 credentials):\n');
      await tester.pumpAndSettle();
      expect(progress, findsNothing);
      expect(fixture.consoleRequests.length, 1);
    },
  );
  testWidgets(
    'file deletion requires final shared confirmation and removes actual file',
    (tester) async {
      await show(
        tester,
        AdminProviderFileRemoval(
          createSession: () => ProviderRecovery.forFileReview(
            fixture.server.profile('personal'),
            ProviderAccess(observation),
          ),
        ),
      );
      await tester.tap(
        find.text('This is the file used by this Claude Code sign-in'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Check file'));
      await tester.pumpAndSettle();
      await reveal(tester, 'Delete credentials');
      await tester.tap(find.text('Delete credentials'));
      await tester.pumpAndSettle();
      expect(fixture.requests.where((r) => r.$1 == 'DELETE'), isEmpty);
      await shot(tester, 'delete-confirm');
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byTooltip('Delete credentials'),
        ),
      );
      await tester.pumpAndSettle();
      expect(fixture.requests.where((r) => r.$1 == 'DELETE').single.$4, {
        'path': '/home/hermes/.claude/.credentials.json',
        'recursive': false,
      });
      expect(
        find.textContaining('No Claude Code credentials are detected.'),
        findsOneWidget,
      );
    },
  );
  testWidgets('native provider removal targets captured profile', (
    tester,
  ) async {
    observation = {
      'id': 'openai-codex',
      'flow': 'device_code',
      'disconnectable': true,
      'status': {
        'logged_in': true,
        'source': 'hermes-auth-store',
        'has_refresh_token': true,
      },
    };
    await show(tester, detail());
    expect(find.text('Renew access'), findsOneWidget);
    expect(find.text('Sign in again'), findsOneWidget);
    await tester.tap(find.text('Remove saved sign-in'));
    await tester.pumpAndSettle();
    expect(find.textContaining('personal on Claw'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove sign-in'));
    await tester.pumpAndSettle();
    expect(fixture.requests.where((r) => r.$1 == 'DELETE').single.$3, {
      'profile': 'personal',
    });
    expect(find.text('Saved sign-in removed.'), findsOneWidget);
  });
  testWidgets('multiple matching entries require an explicit choice', (
    tester,
  ) async {
    fixture.consoleOverride = (_, _, {confirm = false}) async =>
        pool.replaceFirst('hermes_pkce', 'claude_code');
    await show(tester, detail());
    await tester.tap(find.text('Renew access'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a saved sign-in'), findsOneWidget);
    expect(fixture.consoleRequests.where((r) => r.$3), isEmpty);
    await shot(tester, 'credential-choice');
    Navigator.of(tester.element(find.text('Choose a saved sign-in'))).pop();
    await tester.pumpAndSettle();
  });
  testWidgets('unknown credentials never offer renewal or direct deletion', (
    tester,
  ) async {
    observation['status'] = {
      'error': 'unavailable',
      'source': 'claude_code_cli',
      'has_refresh_token': true,
    };
    await show(tester, detail());
    expect(find.text('Renew access'), findsNothing);
    expect(find.text('Delete saved credentials'), findsNothing);
    expect(find.text('Sign-in options'), findsOneWidget);
  });
  testWidgets('expired device sign-in can start again', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    fixture.override = (method, path, query, body) async {
      if (path == 'profiles') {
        return {
          'profiles': [
            {'name': 'personal'},
          ],
        };
      }
      if (path == 'profiles/active') return {'current': 'personal'};
      if (path.endsWith('/start')) {
        return {
          'session_id': 'test-session',
          'flow': 'device_code',
          'expires_in': 900,
          'user_code': 'ABCD-EFGH',
          'poll_interval': 5,
          'verification_url': 'https://example.com/sign-in',
        };
      }
      if (path.contains('/poll/')) {
        return {'session_id': 'test-session', 'status': 'expired'};
      }
      throw StateError('Unexpected $path');
    };
    await show(
      tester,
      AdminProviderSignIn(
        profile: fixture.server.profile('personal'),
        target: const ProviderSignInTarget(id: 'nous', name: 'Nous'),
      ),
    );
    await tester.tap(find.text('Start sign-in'));
    await tester.pumpAndSettle();
    expect(find.text('Copy code'), findsNothing);
    await tester.tap(find.byTooltip('Copy code'));
    await tester.pump();
    expect(copied, 'ABCD-EFGH');
    expect(find.byType(SnackBar), findsNothing);
    await shot(tester, 'device-code-copy');
    await tester.tap(find.text('Check status'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start again'));
    await tester.pumpAndSettle();
    expect(fixture.requests.where((r) => r.$1 == 'POST').length, 2);
    await tester.pumpWidget(const SizedBox());
  });
}
