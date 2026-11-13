import 'package:wing/core/widgets/studio_loading.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'package:wing/core/widgets/profile_default_model_sheet.dart';
import 'package:wing/core/widgets/model_chooser.dart';
import 'package:wing/core/theme/wing_theme.dart';

class _Fixture {
  String provider = 'openai-codex';
  String model = 'gpt-5.6-sol';
  bool confirmRequired = false;
  bool staleReadback = false;
  bool configured = true;
  Completer<void>? postDelay;
  Completer<void>? discoveryDelay;
  int discoveryCalls = 0;
  final reads = <(String, Map<String, String>)>[];
  final posts = <(String, Map<String, dynamic>)>[];

  late final ProfileGateway gateway = ProfileGateway(
    scope: WorkspaceScope(
      connectionId: 'central',
      connectionIdentity: 'profile-model-test',
      profileName: 'work',
    ),
    get: (path, query) async {
      reads.add((path, query));
      if (path == 'model/info') {
        return configured
            ? {'provider': provider, 'model': model}
            : {'provider': '', 'model': ''};
      }
      if (path == 'model/options') {
        return {
          'providers': [
            {
              'slug': 'openai-codex',
              'name': 'OpenAI subscription',
              'models': ['gpt-5.6-sol', 'gpt-6-astra'],
            },
            {
              'slug': 'nous',
              'name': 'Nous',
              'models': ['hermes-4'],
            },
          ],
        };
      }
      throw StateError('Unexpected read $path');
    },
    ownedPost: (path, body, canDispatch, onDispatched) async {
      if (!canDispatch()) throw StateError('Retired model write');
      onDispatched();
      posts.add((path, Map<String, dynamic>.from(body)));
      await postDelay?.future;
      if (confirmRequired && body['confirm_expensive_model'] != true) {
        return {
          'ok': false,
          'confirm_required': true,
          'confirm_message': 'This route may cost more.',
        };
      }
      if (!staleReadback) {
        provider = body['provider'] as String;
        model = body['model'] as String;
        configured = true;
      }
      return {'ok': true};
    },
    rpc: (_, _) async => {},
    discover: () async {
      discoveryCalls++;
      await discoveryDelay?.future;
      return const ProfileDiscovery(
        profiles: [HermesProfile(name: 'work')],
        currentName: 'work',
        activeName: 'work',
      );
    },
  );
}

void main() {
  const capture = bool.fromEnvironment('CAPTURE_MODEL_REVIEW');
  setUpAll(() async {
    final config = File('.dart_tool/package_config.json').absolute;
    final packages =
        (jsonDecode(await config.readAsString()) as Map)['packages'] as List;
    final flutter = packages.cast<Map>().singleWhere(
      (package) => package['name'] == 'flutter',
    );
    final packageRoot = Directory.fromUri(
      config.uri.resolve(flutter['rootUri'] as String),
    );
    final root =
        '${packageRoot.parent.parent.path}/bin/cache/artifacts/material_fonts';
    for (final font in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            File(
              '$root/${font.value}',
            ).readAsBytes().then((bytes) => bytes.buffer.asByteData()),
          ))
          .load();
    }
  });
  late _Fixture fixture;
  bool? result;

  setUp(() {
    fixture = _Fixture();
    result = null;
  });

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(800, 900),
    double keyboard = 0,
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: RepaintBoundary(
            key: const ValueKey('model-review-capture'),
            child: child!,
          ),
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                result = await showProfileDefaultModelSheet(
                  context,
                  gateway: fixture.gateway,
                  connectionLabel: 'Central server',
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Future<void> selectAstra(WidgetTester tester) async {
    final choice = find.byKey(
      const Key('profile-model-openai-codex-gpt-6-astra'),
    );
    await tester.ensureVisible(choice);
    await tester.tap(choice);
    await tester.pump();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('profile-model-save')));
    await tester.pumpAndSettle();
  }

  testWidgets('loads explicit options and saves the captured profile scope', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('work on Central server'), findsOneWidget);
    expect(find.text('For new chats only'), findsOneWidget);
    expect(fixture.reads.singleWhere((read) => read.$1 == 'model/options').$2, {
      'explicit_only': '1',
      'profile': 'work',
    });

    await selectAstra(tester);
    await save(tester);

    expect(fixture.discoveryCalls, 1);
    expect(fixture.posts, hasLength(1));
    expect(fixture.posts.single.$1, 'model/set?profile=work');
    expect(fixture.posts.single.$2, {
      'scope': 'main',
      'provider': 'openai-codex',
      'model': 'gpt-6-astra',
    });
    expect(result, isTrue);
  });

  testWidgets(
    'main model conflict review retains the wanted pair and explicitly recovers in the sheet',
    (tester) async {
      await open(tester);
      await selectAstra(tester);
      fixture.provider = 'nous';
      fixture.model = 'hermes-4';
      await save(tester);

      // Actual conflict refusal, retained intent and route precede recovery.
      expect(fixture.posts, isEmpty);
      expect(fixture.provider, 'nous');
      expect(fixture.model, 'hermes-4');
      expect(result, isNull);
      expect(find.byType(ProfileDefaultModelSheet), findsOneWidget);
      expect(find.textContaining('changed elsewhere'), findsOneWidget);
      expect(
        tester
            .widget<ModelChooser>(find.byType(ModelChooser))
            .selected!
            .choice!
            .model,
        'gpt-6-astra',
      );
      expect(find.text('Review changes').hitTestable(), findsOneWidget);

      await tester.tap(find.text('Review changes'));
      await tester.pumpAndSettle();
      expect(find.text('Review model change'), findsOneWidget);
      expect(find.text('nous / hermes-4'), findsOneWidget);
      expect(find.text('openai-codex / gpt-6-astra'), findsOneWidget);
      await tester.tap(find.byTooltip('Keep my model selection'));
      await tester.pumpAndSettle();
      expect(fixture.posts, isEmpty);
      expect(find.text('Review model change'), findsNothing);
      expect(
        tester
            .widget<ModelChooser>(find.byType(ModelChooser))
            .selected!
            .choice!
            .model,
        'gpt-6-astra',
      );
      await save(tester);
      expect(fixture.posts, hasLength(1));
      expect(fixture.posts.single.$1, 'model/set?profile=work');
      expect(fixture.posts.single.$2, {
        'scope': 'main',
        'provider': 'openai-codex',
        'model': 'gpt-6-astra',
      });
      expect(result, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Cancel review keeps the pending pair and requires another explicit review',
    (tester) async {
      await open(tester);
      await selectAstra(tester);
      fixture.provider = 'nous';
      fixture.model = 'hermes-4';
      await save(tester);
      await tester.tap(find.text('Review changes'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byTooltip('Cancel'),
        ),
      );
      await tester.pumpAndSettle();
      expect(fixture.posts, isEmpty);
      expect(
        tester
            .widget<ModelChooser>(find.byType(ModelChooser))
            .selected!
            .choice!
            .model,
        'gpt-6-astra',
      );
      await save(tester);
      expect(fixture.posts, isEmpty);
      expect(find.text('Review changes').hitTestable(), findsOneWidget);
      expect(result, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Use server adopts automatic identity without sending or closing the sheet',
    (tester) async {
      await open(tester);
      await selectAstra(tester);
      fixture.provider = '';
      fixture.model = 'automatic-choice';
      await save(tester);
      await tester.tap(find.text('Review changes'));
      await tester.pumpAndSettle();
      expect(
        find.text('Automatic provider / automatic-choice'),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Use server model'));
      await tester.pumpAndSettle();
      expect(fixture.posts, isEmpty);
      expect(
        tester.widget<ModelChooser>(find.byType(ModelChooser)).selected,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('profile-model-save')))
            .onPressed,
        isNull,
      );
      expect(result, isNull);
      expect(find.byType(ProfileDefaultModelSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in [Brightness.light, Brightness.dark]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'model review is reachable at 320px ${brightness.name} ${scale}x',
        (tester) async {
          await open(
            tester,
            size: const Size(320, 900),
            brightness: brightness,
            scale: scale,
          );
          await selectAstra(tester);
          fixture.provider = 'nous';
          fixture.model = 'hermes-4';
          await save(tester);
          expect(fixture.posts, isEmpty);
          expect(find.text('Review changes').hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('Review changes'));
          await tester.pumpAndSettle();
          for (final label in [
            'Cancel',
            'Use server model',
            'Keep my model selection',
          ]) {
            final action = find.descendant(
              of: find.byType(AlertDialog),
              matching: find.byTooltip(label),
            );
            expect(action.hitTestable(), findsOneWidget);
            final button = find.ancestor(
              of: action,
              matching: find.byWidgetPredicate(
                (widget) => widget is IconButton,
              ),
            );
            expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
          }
          expect(find.text('nous / hermes-4'), findsOneWidget);
          expect(find.text('openai-codex / gpt-6-astra'), findsOneWidget);
          expect(tester.takeException(), isNull);
          if (capture) {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('model-review-capture')),
            );
            await tester.runAsync(() async {
              final image = await boundary.toImage(pixelRatio: 1);
              try {
                final data = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final output = File(
                  'build/model-review/conflict-${brightness.name}-${scale}x.png',
                );
                await output.parent.create(recursive: true);
                await output.writeAsBytes(data!.buffer.asUint8List());
              } finally {
                image.dispose();
              }
            });
          }
          await tester.tap(find.byTooltip('Keep my model selection'));
          await tester.pumpAndSettle();
          expect(fixture.posts, isEmpty);
          expect(
            tester
                .widget<ModelChooser>(find.byType(ModelChooser))
                .selected!
                .choice!
                .model,
            'gpt-6-astra',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final dismissal in ['Back', 'Close']) {
    testWidgets(
      '$dismissal cancels a pending model choice without a write or dirty dialog',
      (tester) async {
        await open(tester);
        await selectAstra(tester);
        expect(
          tester
              .widget<IconButton>(find.byKey(const Key('profile-model-save')))
              .onPressed,
          isNotNull,
        );
        expect(fixture.posts, isEmpty);
        if (dismissal == 'Back') {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byTooltip('Cancel'));
        }
        await tester.pumpAndSettle();
        expect(result, isFalse);
        expect(fixture.posts, isEmpty);
        expect(find.byType(ProfileDefaultModelSheet), findsNothing);
        expect(find.byType(AlertDialog), findsNothing);
        expect(fixture.model, 'gpt-5.6-sol');
        result = null;
        await open(tester);
        expect(
          tester
              .widget<ModelChooser>(find.byType(ModelChooser))
              .selected!
              .choice!
              .model,
          'gpt-5.6-sol',
        );
        expect(
          fixture.reads.where((read) => read.$1 == 'model/info'),
          hasLength(2),
        );
        expect(fixture.posts, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'retired sheet cannot dispatch after delayed profile validation',
    (tester) async {
      await open(tester);
      await selectAstra(tester);
      fixture.discoveryDelay = Completer<void>();
      await tester.tap(find.byKey(const Key('profile-model-save')));
      await tester.pump();
      expect(fixture.discoveryCalls, 1);
      await tester.pumpWidget(const SizedBox());
      fixture.discoveryDelay!.complete();
      await tester.pumpAndSettle();
      expect(fixture.posts, isEmpty);
    },
  );

  testWidgets('confirmation denial does not retry or report success', (
    tester,
  ) async {
    fixture.confirmRequired = true;
    await open(tester);
    await selectAstra(tester);
    await tester.tap(find.byKey(const Key('profile-model-save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('This route may cost more.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('profile-model-confirm-cancel')));
    await tester.pumpAndSettle();

    expect(fixture.posts, hasLength(1));
    expect(fixture.discoveryCalls, 1);
    expect(find.text('Model change cancelled.'), findsOneWidget);
    expect(result, isNull);
  });

  testWidgets('confirmation acceptance revalidates and retries explicitly', (
    tester,
  ) async {
    fixture.confirmRequired = true;
    await open(tester);
    await selectAstra(tester);
    await tester.tap(find.byKey(const Key('profile-model-save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('This route may cost more.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('profile-model-confirm-accept')));
    await tester.pumpAndSettle();

    expect(fixture.discoveryCalls, 2);
    expect(fixture.posts, hasLength(2));
    expect(fixture.posts.last.$2['confirm_expensive_model'], isTrue);
    expect(result, isTrue);
  });

  testWidgets('successful ACK with mismatched readback stays open as failure', (
    tester,
  ) async {
    fixture.staleReadback = true;
    await open(tester);
    await selectAstra(tester);
    await save(tester);

    expect(
      find.text(
        'The model change could not be confirmed. Review the selection and try again.',
      ),
      findsOneWidget,
    );
    expect(result, isNull);
  });

  testWidgets('filters the model list by provider and model text', (
    tester,
  ) async {
    await open(tester);

    await tester.enterText(
      find.byKey(const Key('profile-model-search')),
      'nous',
    );
    await tester.pump();
    expect(find.text('Nous'), findsWidgets);
    expect(
      find.byKey(const Key('profile-model-provider-openai-codex')),
      findsNothing,
    );

    await tester.enterText(
      find.byKey(const Key('profile-model-search')),
      'missing-model',
    );
    await tester.pump();
    expect(find.text('No matching models'), findsOneWidget);
  });

  testWidgets('system back is blocked while saving and success closes sheet', (
    tester,
  ) async {
    fixture.postDelay = Completer<void>();
    await open(tester);
    await selectAstra(tester);

    await tester.tap(find.byKey(const Key('profile-model-save')));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(StudioLoading), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('Profile default model'), findsOneWidget);
    expect(result, isNull);

    fixture.postDelay!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Profile default model'), findsNothing);
    expect(result, isTrue);
  });

  testWidgets('an unconfigured profile can select and save its first default', (
    tester,
  ) async {
    fixture.configured = false;
    await open(tester);

    await selectAstra(tester);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('profile-model-save')))
          .onPressed,
      isNotNull,
    );
    await save(tester);

    expect(fixture.posts, hasLength(1));
    expect(fixture.posts.single.$2['model'], 'gpt-6-astra');
    expect(result, isTrue);
  });

  testWidgets('search and save actions fit above a small-screen keyboard', (
    tester,
  ) async {
    await open(tester, size: const Size(320, 640), keyboard: 240);

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('profile-model-search')), findsOneWidget);
    expect(find.byKey(const Key('profile-model-save')), findsOneWidget);
    expect(
      find.byKey(const Key('profile-model-save')).hitTestable(),
      findsOneWidget,
    );
  });
}
