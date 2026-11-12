import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:wing/core/widgets/chat_model_controls.dart';
import 'package:wing/core/models/chat_intelligence.dart';
import 'package:wing/core/models/model_choice.dart';
import 'package:wing/core/models/model_catalog.dart';
import 'package:wing/core/models/models_dev_prices.dart';
import 'package:wing/core/presentation/chat_model_labels.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/chat_intelligence_picker.dart';
import 'package:wing/core/widgets/model_card.dart';

void main() {
  final catalog = ModelCatalog.fromOptions(
    {
      'providers': [
        {
          'slug': 'openai-codex',
          'name': 'OpenAI subscription',
          'models': ['gpt-6-astra', 'gpt-5.6-sol'],
          'capabilities': {
            for (final id in ['gpt-6-astra', 'gpt-5.6-sol'])
              id: {'reasoning': true, 'fast': true},
          },
        },
        {
          'slug': 'openrouter',
          'name': 'OpenRouter',
          'models': ['openai/gpt-5.6-sol'],
        },
      ],
    },
    apiPrices: ModelsDevPrices.fromJson({
      'openai': {
        'models': {
          'gpt-6-astra': {
            'cost': {'input': 5, 'output': 25, 'cache_read': 0.5},
          },
        },
      },
    }),
  );
  final choices = catalog.choices;
  Future<void> open(
    WidgetTester tester, {
    Future<bool> Function(ChatIntelligenceSelection)? commit,
    ValueChanged<ChatIntelligenceSelection>? apply,
    VoidCallback? cancel,
    List<ModelChoice>? rows,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: wingTheme(Brightness.dark),
      home: Scaffold(
        body: ChatIntelligenceSheet(
          choices: rows ?? choices,
          initialChoice: (rows ?? choices).first,
          initialReasoningEffort: 'high',
          initialFastMode: ChatFastMode.normal,
          defaultModel: choices.first.model,
          profileName: 'personal',
          onRefreshModels: () async => rows ?? choices,
          onReviewProviderAccess: () {},
          onApply: apply ?? (_) {},
          onCancel: cancel ?? () {},
          onCommit: commit ?? (_) async => true,
        ),
      ),
    ),
  );

  test('composer formatting leaves route identity intact', () {
    expect(compactChatModelLabel('openai/gpt-5.6-sol'), '5.6 Sol');
    expect(catalogModelLabel('gpt-6-astra'), 'GPT-6 Astra');
  });

  test('composer reasoning badges stay short', () {
    const expected = {
      'none': 'O',
      'minimal': 'Min',
      'low': 'L',
      'medium': 'Med',
      'high': 'H',
      'xhigh': 'X',
      'max': 'Max',
      'ultra': 'U',
      'default': 'D',
      '': 'D',
    };
    for (final entry in expected.entries) {
      expect(compactChatReasoningLabel(entry.key), entry.value);
    }
  });

  testWidgets(
    'held reasoning retires when disabled; unavailable Off stays absent',
    (tester) async {
      final writes = <String>[];
      Future<void> render(bool enabled) => tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ChatReasoningScrubControl(
                effort: 'high',
                canDisable: false,
                onChanged: enabled ? writes.add : null,
              ),
            ),
          ),
        ),
      );
      await render(true);
      final control = find.byKey(const Key('composer-reasoning-control'));
      final held = await tester.startGesture(tester.getCenter(control));
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        find.byKey(const Key('composer-reasoning-selector')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('composer-reasoning-choice-none')),
        findsNothing,
      );
      await held.moveTo(
        tester.getCenter(
          find.byKey(const Key('composer-reasoning-choice-low')),
        ),
      );
      await render(false);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('composer-reasoning-selector')),
        findsNothing,
      );
      await held.up();
      await tester.pumpAndSettle();
      expect(writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  Future<void> renderReasoning(
    WidgetTester tester,
    List<String> writes, {
    bool enabled = true,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: wingTheme(Brightness.dark),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: ChatReasoningScrubControl(
            effort: 'high',
            canDisable: false,
            onChanged: enabled ? writes.add : null,
          ),
        ),
      ),
    ),
  );

  testWidgets('reasoning tap selects one level and closes the selector', (
    tester,
  ) async {
    final writes = <String>[];
    await renderReasoning(tester, writes);
    await tester.tap(find.byKey(const Key('composer-reasoning-control')));
    await tester.pumpAndSettle();
    final medium = find.byKey(const Key('composer-reasoning-choice-medium'));
    expect(medium.hitTestable(), findsOneWidget);
    expect(
      find.byKey(const Key('composer-reasoning-choice-none')),
      findsNothing,
    );
    expect(writes, isEmpty);
    await tester.tap(medium);
    await tester.pumpAndSettle();
    expect(writes, ['medium']);
    expect(find.byKey(const Key('composer-reasoning-selector')), findsNothing);
  });

  for (final dismissal in ['Escape', 'outside tap', 'disabled control']) {
    testWidgets('reasoning $dismissal dismisses without committing', (
      tester,
    ) async {
      final writes = <String>[];
      await renderReasoning(tester, writes);
      final control = find.byKey(const Key('composer-reasoning-control'));
      await tester.tap(control);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('composer-reasoning-selector')),
        findsOneWidget,
      );
      switch (dismissal) {
        case 'Escape':
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        case 'outside tap':
          await tester.tapAt(
            tester.getTopLeft(find.byType(Scaffold)) + const Offset(8, 8),
          );
        case 'disabled control':
          await renderReasoning(tester, writes, enabled: false);
      }
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('composer-reasoning-selector')),
        findsNothing,
      );
      expect(writes, isEmpty);
      if (dismissal == 'disabled control') {
        await tester.tap(control);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('composer-reasoning-selector')),
          findsNothing,
        );
        expect(writes, isEmpty);
      }
    });
  }

  testWidgets(
    'reasoning keyboard uses the same selector and commits with Enter',
    (tester) async {
      final writes = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ChatReasoningScrubControl(
                effort: 'high',
                canDisable: false,
                onChanged: writes.add,
              ),
            ),
          ),
        ),
      );
      final control = find.byKey(const Key('composer-reasoning-control'));
      FocusScope.of(tester.element(control)).nextFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('composer-reasoning-choice-none')),
        findsNothing,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(writes, ['medium']);
      expect(
        find.byKey(const Key('composer-reasoning-selector')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('one ledger stages all settings, then applies once', (
    tester,
  ) async {
    ChatIntelligenceSelection? result;
    await open(tester, apply: (value) => result = value);
    expect(find.text('Models'), findsOneWidget);
    expect(find.byKey(const Key('reasoning-high')), findsNothing);
    await tester.tap(find.byKey(const Key('model-openai-codex-gpt-5.6-sol')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('model-search')), findsOneWidget);
    await tester.tap(find.byKey(const Key('chat-reasoning-control')));
    await tester.pumpAndSettle();
    for (final effort in chatReasoningEffortLabels.keys) {
      expect(
        find.byKey(Key('reasoning-$effort')).hitTestable(),
        findsOneWidget,
      );
      expect(
        tester.getSize(find.byKey(Key('reasoning-$effort'))).height,
        greaterThanOrEqualTo(48),
      );
    }
    await tester.tap(find.byKey(const Key('reasoning-ultra')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-fast-control')));
    await tester.pump();
    expect(result, isNull);
    expect(find.text('On'), findsOneWidget);
    await tester.tap(find.byTooltip('Apply model settings'));
    await tester.pumpAndSettle();
    expect(result?.choice.model, 'gpt-5.6-sol');
    expect(result?.reasoningEffort, 'ultra');
    expect(result?.fastMode, ChatFastMode.fast);
  });

  testWidgets('missing metadata hides controls and card shows supplied facts', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('info-openai-codex-gpt-6-astra')));
    await tester.pumpAndSettle();
    expect(find.byType(ModelCard), findsOneWidget);
    expect(find.text(r'$5.00'), findsWidgets);
    expect(find.text('Vision'), findsNothing);
    expect(find.text('Context window'), findsNothing);
    await tester.tap(find.byTooltip('Close model card'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('model-filter-all')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('model-openrouter-openai/gpt-5.6-sol')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-reasoning-control')), findsNothing);
    expect(find.byKey(const Key('chat-fast-control')), findsNothing);
  });

  testWidgets('failure retains draft; pending commit locks all editing', (
    tester,
  ) async {
    final pending = Completer<bool>();
    addTearDown(() {
      if (!pending.isCompleted) pending.complete(false);
    });
    var calls = 0;
    ChatIntelligenceSelection? applied;
    await open(
      tester,
      commit: (_) {
        calls++;
        return calls == 1 ? pending.future : Future.value(true);
      },
      apply: (value) => applied = value,
    );
    await tester.tap(find.byKey(const Key('model-openai-codex-gpt-5.6-sol')));
    await tester.tap(find.byTooltip('Apply model settings'));
    await tester.pump();
    expect(find.byTooltip('Apply model settings'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('info-openai-codex-gpt-5.6-sol')),
          )
          .onPressed,
      isNull,
    );
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == 'Close',
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('Apply model settings'));
    await tester.pump(const Duration(seconds: 2));
    expect(calls, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pending.completeError(StateError('Fast setting rejected'));
    await tester.pumpAndSettle();
    expect(find.text('Fast setting rejected'), findsOneWidget);
    expect(
      find.byKey(const Key('model-openai-codex-gpt-5.6-sol')),
      findsOneWidget,
    );
    expect(find.byTooltip('Apply model settings'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.byTooltip('Apply model settings'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(applied?.choice.model, 'gpt-5.6-sol');
  });

  testWidgets('cancel never commits a changed draft', (tester) async {
    var commits = 0, cancels = 0;
    await open(
      tester,
      commit: (_) async {
        commits++;
        return true;
      },
      cancel: () => cancels++,
    );
    await tester.tap(find.byKey(const Key('chat-fast-control')));
    await tester.tap(find.byTooltip('Close'));
    expect(commits, 0);
    expect(cancels, 1);
  });

  testWidgets('cannot-disable metadata removes only Off', (tester) async {
    final rows = ModelCatalog.fromOptions({
      'providers': [
        {
          'slug': 'openai',
          'name': 'OpenAI',
          'models': ['gpt-6-astra'],
          'capabilities': {
            'gpt-6-astra': {
              'reasoning': true,
              'fast': false,
              'can_disable_reasoning': false,
            },
          },
        },
      ],
    }).choices;
    await open(tester, rows: rows);
    await tester.tap(find.byKey(const Key('chat-reasoning-control')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reasoning-none')), findsNothing);
    expect(find.byKey(const Key('reasoning-minimal')), findsOneWidget);
  });
  testWidgets(
    'manual model stays staged and cannot contain gateway command flags',
    (tester) async {
      ChatIntelligenceSelection? selected;
      await open(tester, apply: (value) => selected = value);
      await tester.tap(find.byTooltip('More model options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enter model ID'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('manual-model-id')),
        'model --global',
      );
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton && widget.tooltip == 'Use model',
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const Key('manual-model-id')),
        'my/model',
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Use model'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(selected, isNull);
      await tester.tap(find.byTooltip('Apply model settings'));
      await tester.pumpAndSettle();
      expect(selected!.choice.model, 'my/model');
      expect(selected!.choice.provider, 'openai-codex');
      expect(selected!.fastMode, ChatFastMode.normal);
    },
  );
}
