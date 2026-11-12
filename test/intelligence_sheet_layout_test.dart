import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/chat_intelligence.dart';
import 'package:wing/core/models/model_catalog.dart';
import 'package:wing/core/models/models_dev_prices.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/chat_intelligence_picker.dart';

void main() {
  const capture = bool.fromEnvironment('CAPTURE_INTELLIGENCE');
  const frame = Key('intelligence-preview');
  final choices = ModelCatalog.fromOptions(
    {
      'providers': [
        {
          'slug': 'openai-codex',
          'name': 'ChatGPT or Codex subscription',
          'models': [
            'gpt-6.1-sol',
            'gpt-6-astra',
            'gpt-6-sol',
            'gpt-6-luna',
            'gpt-5.6-sol',
          ],
          'capabilities': {
            for (final id in [
              'gpt-6.1-sol',
              'gpt-6-astra',
              'gpt-6-sol',
              'gpt-6-luna',
              'gpt-5.6-sol',
            ])
              id: {'reasoning': true, 'fast': true},
          },
        },
        {
          'slug': 'openrouter',
          'name': 'OpenRouter',
          'models': ['anthropic/claude-sonnet-4.6', 'google/gemini-3-pro'],
          'pricing': {
            'anthropic/claude-sonnet-4.6': {
              'input': r'$3.00',
              'output': r'$15.00',
              'free': false,
            },
          },
        },
      ],
    },
    apiPrices: ModelsDevPrices.fromJson({
      'openai': {
        'models': {
          for (final id in [
            'gpt-6.1-sol',
            'gpt-6-astra',
            'gpt-6-sol',
            'gpt-6-luna',
            'gpt-5.6-sol',
          ])
            id: {
              'cost': {'input': 5, 'output': 25, 'cache_read': 0.5},
            },
        },
      },
    }),
  ).choices;
  setUpAll(() async {
    if (!capture) return;
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'Ahem': 'build/studio-roboto.ttf',
      'monospace': 'build/studio-mono.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
    }.entries) {
      final bytes = File(entry.value).readAsBytesSync();
      await (FontLoader(
        entry.key,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
  });
  for (final brightness in Brightness.values) {
    for (final (size, scale) in [
      (const Size(390, 844), 1.0),
      (const Size(320, 640), 2.0),
      (const Size(823, 412), 1.0),
    ]) {
      testWidgets('compact model sheet $brightness $size text $scale', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        ChatIntelligenceSelection? result;
        await tester.pumpWidget(
          RepaintBoundary(
            key: frame,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => Center(
                    child: TextButton(
                      onPressed: () async {
                        result = await showChatIntelligencePicker(
                          context: context,
                          choices: choices,
                          initialChoice: choices.first,
                          initialReasoningEffort: 'high',
                          initialFastMode: ChatFastMode.normal,
                          defaultModel: choices.first.model,
                          profileName: 'personal',
                          refreshModels: () async => choices,
                          reviewProviderAccess: () async {},
                          onCommit: (_) async => true,
                        );
                      },
                      child: const Text('Open models'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open models'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.byTooltip('Apply model settings').hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('model-search')).hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('chat-reasoning-control')).hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('chat-fast-control')).hitTestable(),
          findsOneWidget,
        );
        final prefix =
            'build/model-picker-${brightness.name}-${size.width.toInt()}-${scale == 2 ? 'large' : 'normal'}';
        Future<void> screenshot(String suffix) async {
          if (!capture) return;
          await tester.runAsync(() async {
            final image = await tester
                .renderObject<RenderRepaintBoundary>(find.byKey(frame))
                .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '$prefix-$suffix.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        await screenshot('list');
        await tester.tap(
          find.byKey(const Key('info-openai-codex-gpt-6.1-sol')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await screenshot('card');
        await tester.tap(find.byTooltip('Close model card'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('chat-reasoning-control')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await screenshot('reasoning');
        await tester.tap(find.byKey(const Key('reasoning-ultra')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('chat-fast-control')));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Apply model settings'));
        await tester.pumpAndSettle();
        expect(result?.reasoningEffort, 'ultra');
        expect(result?.fastMode, ChatFastMode.fast);
        expect(tester.takeException(), isNull);
      });
    }
  }
  for (final brightness in Brightness.values) {
    for (final priced in [false, true]) {
      testWidgets(
        'all Codex choices remain selectable with the form footer $brightness priced $priced',
        (tester) async {
          tester.view.physicalSize = const Size(412, 832);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final catalog = ModelCatalog.fromOptions(
            {
              'providers': [
                {
                  'slug': 'openrouter',
                  'name': 'OpenRouter',
                  'models': ['anthropic/claude-sonnet-4.6'],
                },
                {
                  'slug': 'openai-codex',
                  'name': 'ChatGPT or Codex Subscription',
                  'models': [
                    'gpt-6.1-sol',
                    'gpt-6.1-sol-900k',
                    'gpt-6-astra',
                    'gpt-6-astra-900k',
                    'gpt-6-sol',
                    'gpt-6-sol-900k',
                    'gpt-6-luna',
                    'gpt-6-luna-900k',
                    'gpt-5.6-sol',
                    'gpt-5.6-sol-900k',
                    'gpt-5.6-terra',
                    'gpt-5.6-terra-900k',
                    'gpt-5.6-luna',
                    'gpt-5.6-luna-900k',
                  ],
                  'capabilities': {
                    'gpt-6.1-sol': {'reasoning': true, 'fast': true},
                  },
                },
              ],
            },
            apiPrices: !priced
                ? null
                : ModelsDevPrices.fromJson({
                    'openai': {
                      'models': {
                        for (final id in [
                          'gpt-6.1-sol',
                          'gpt-6-astra',
                          'gpt-6-sol',
                          'gpt-6-luna',
                          'gpt-5.6-sol',
                        ])
                          id: {
                            'cost': {
                              'input': 5,
                              'output': 25,
                              'cache_read': 0.5,
                            },
                          },
                      },
                    },
                  }),
          ).choices;
          final active = catalog.firstWhere((c) => c.model == 'gpt-6.1-sol');
          ChatIntelligenceSelection? result;
          await tester.pumpWidget(
            RepaintBoundary(
              key: frame,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: wingTheme(brightness),
                home: Scaffold(
                  body: Builder(
                    builder: (context) => TextButton(
                      onPressed: () async {
                        result = await showChatIntelligencePicker(
                          context: context,
                          choices: catalog,
                          initialChoice: active,
                          initialReasoningEffort: 'high',
                          initialFastMode: ChatFastMode.normal,
                          defaultModel: active.model,
                          profileName: 'Claw',
                          refreshModels: () async => catalog,
                          reviewProviderAccess: () async {},
                          onCommit: (_) async => true,
                        );
                      },
                      child: const Text('Open models'),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open models'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final first = find.byKey(const Key('model-openai-codex-gpt-6.1-sol'));
          final last = find.byKey(
            const Key('model-openai-codex-gpt-5.6-luna-900k'),
          );
          expect(first.hitTestable(), findsOneWidget);
          expect(
            last.hitTestable(),
            findsOneWidget,
            reason: 'All 14 Codex models must fit on a normal phone',
          );
          if (priced) {
            expect(find.text('API equivalent · per 1M tokens'), findsOneWidget);
          }
          expect(
            find.byTooltip('Apply model settings').hitTestable(),
            findsOneWidget,
          );
          if (capture) {
            await tester.runAsync(() async {
              final image = await tester
                  .renderObject<RenderRepaintBoundary>(find.byKey(frame))
                  .toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                'build/model-picker-${brightness.name}-412-full-list-${priced ? 'priced' : 'unpriced'}.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          await tester.tap(last);
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Apply model settings'));
          await tester.pumpAndSettle();
          expect(result?.choice.model, 'gpt-5.6-luna-900k');
          expect(find.byType(BottomSheet), findsNothing);
        },
      );
    }
  }
}
