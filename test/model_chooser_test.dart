import 'package:wing/core/models/model_choice.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/model_catalog_details.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/model_card.dart';
import 'package:wing/core/widgets/model_chooser.dart';

Future<FocusNode> focusModelRow(WidgetTester tester, Key key) async {
  final radio = tester.widget<RawRadio<ModelSelection>>(
    find.descendant(
      of: find.byKey(key),
      matching: find.byType(RawRadio<ModelSelection>),
    ),
  );
  final focus = radio.focusNode;
  focus.requestFocus();
  await tester.pump();
  expect(focus.hasPrimaryFocus, isTrue);
  return focus;
}

void main() {
  const first = ModelChoice(provider: 'alpha', model: 'shared');
  const second = ModelChoice(provider: 'beta', model: 'shared');

  for (final grouped in [false, true]) {
    testWidgets(
      'API units remain visible with an unpriced first choice, grouped $grouped',
      (tester) async {
        const unknown = ModelChoice(provider: 'subscription', model: 'unknown');
        final known = ModelChoice(
          provider: 'subscription',
          model: 'known',
          prices: ModelPrices.api(input: 2, output: 10, cache: 0.2),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(Brightness.dark),
            home: Scaffold(
              body: ModelChooser(
                choices: [unknown, known],
                selected: const ModelSelection.model(unknown),
                onSelected: (_) {},
                groupByProvider: grouped,
                scopeLabel: 'Subscription models',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('API equivalent · per 1M tokens'), findsOneWidget);
        expect(find.text(r'$2.00'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('arrow keys traverse models and named special choices', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      ModelSelection selected = const ModelSelection.model(first);
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => ModelChooser(
                choices: const [first, second],
                selected: selected,
                onSelected: (value) => update(() => selected = value),
                groupByProvider: false,
                specialOptions: const [
                  ModelSpecialOption(ModelSpecialChoice.automatic, 'Automatic'),
                  ModelSpecialOption(
                    ModelSpecialChoice.profileDefault,
                    'Profile default',
                  ),
                ],
                scopeLabel: 'Model keyboard navigation',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final firstRow = find.byKey(const Key('model-alpha-shared'));
      expect(
        tester.getSemantics(firstRow),
        isSemantics(
          isChecked: true,
          isSelected: true,
          isInMutuallyExclusiveGroup: true,
        ),
      );
      await focusModelRow(tester, const Key('model-alpha-shared'));
      for (final step in [
        (LogicalKeyboardKey.arrowDown, const ModelSelection.model(second)),
        (
          LogicalKeyboardKey.arrowDown,
          const ModelSelection.special(ModelSpecialChoice.automatic),
        ),
        (
          LogicalKeyboardKey.arrowDown,
          const ModelSelection.special(ModelSpecialChoice.profileDefault),
        ),
        (
          LogicalKeyboardKey.arrowUp,
          const ModelSelection.special(ModelSpecialChoice.automatic),
        ),
        (LogicalKeyboardKey.arrowUp, const ModelSelection.model(second)),
        (LogicalKeyboardKey.arrowLeft, const ModelSelection.model(first)),
        (LogicalKeyboardKey.arrowRight, const ModelSelection.model(second)),
      ]) {
        await tester.sendKeyEvent(step.$1);
        await tester.pumpAndSettle();
        expect(selected, step.$2);
      }
      expect(
        tester.getSemantics(firstRow),
        isSemantics(isChecked: false, isSelected: false),
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('Tab reaches separate info without changing the model', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final selections = <ModelSelection>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.light),
          home: Scaffold(
            body: ModelChooser(
              choices: const [first, second],
              selected: const ModelSelection.model(first),
              onSelected: selections.add,
              groupByProvider: false,
              scopeLabel: 'Model info keyboard navigation',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await focusModelRow(tester, const Key('model-alpha-shared'));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final info = find.byKey(const Key('info-alpha-shared'));
      expect(tester.getSemantics(info), isSemantics(isFocused: true));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(
        tester.getSemantics(find.byKey(const Key('model-alpha-shared'))),
        isSemantics(isFocused: true),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(find.byType(ModelCard), findsOneWidget);
      expect(tester.widget<ModelCard>(find.byType(ModelCard)).choice, first);
      expect(selections, isEmpty);
      await tester.tap(find.byTooltip('Close model card'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('model-beta-shared')));
      expect(selections, [const ModelSelection.model(second)]);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'disabled chooser retires focus and blocks model and info input',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final selections = <ModelSelection>[];
        Future<void> render(bool enabled) => tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(Brightness.dark),
            home: Scaffold(
              body: ModelChooser(
                choices: const [first, second],
                selected: const ModelSelection.model(first),
                onSelected: selections.add,
                groupByProvider: false,
                enabled: enabled,
                scopeLabel: 'Disabled model input',
              ),
            ),
          ),
        );
        await render(true);
        await tester.pumpAndSettle();
        final focus = await focusModelRow(
          tester,
          const Key('model-alpha-shared'),
        );
        await render(false);
        await tester.pumpAndSettle();
        expect(focus.canRequestFocus, isFalse);
        expect(focus.hasFocus, isFalse);
        expect(
          tester.getSemantics(find.byKey(const Key('model-alpha-shared'))),
          isSemantics(isChecked: true, isSelected: true, isEnabled: false),
        );
        await tester.tap(find.byKey(const Key('model-beta-shared')));
        await tester.tap(find.byKey(const Key('info-alpha-shared')));
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(selections, isEmpty);
        expect(find.byType(ModelCard), findsNothing);
      } finally {
        semantics.dispose();
      }
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('model prices and selection remain usable '
          'in $brightness at $scale text scale', (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        const priced = ModelChoice(
          provider: 'alpha',
          model: 'first',
          prices: ModelPrices(input: r'$1', output: r'$2', free: false),
        );
        const long = ModelChoice(
          provider: 'alpha',
          model: 'long-model-name',
          displayName: 'A long model name with supplied price information',
          prices: ModelPrices(input: r'$3', output: r'$4', free: false),
        );
        ModelSelection? selected;
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: ModelChooser(
                choices: const [priced, long],
                selected: const ModelSelection.model(priced),
                onSelected: (value) => selected = value,
                groupByProvider: false,
                scopeLabel: 'Priced models',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final row = find.byKey(const Key('model-alpha-first'));
        if (scale == 1) {
          for (final price in [r'$1', r'$2']) {
            expect(
              find.descendant(of: row, matching: find.text(price)),
              findsOneWidget,
            );
          }
        } else {
          expect(
            find.descendant(of: row, matching: find.text(r'In $1 · Out $2')),
            findsOneWidget,
          );
        }
        final alternative = find.byKey(
          const Key('model-alpha-long-model-name'),
        );
        await tester.ensureVisible(alternative);
        await tester.pumpAndSettle();
        await tester.tap(alternative);
        await tester.pump();
        expect(selected, const ModelSelection.model(long));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'opens on the active route even when it is last in a long catalog',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        const active = ModelChoice(
          provider: 'openai-codex',
          providerLabel: 'ChatGPT or Codex Subscription',
          model: 'gpt-6.1-sol',
        );
        final choices = [
          for (var i = 0; i < 45; i++)
            ModelChoice(provider: 'openrouter', model: 'other-$i'),
          const ModelChoice(provider: 'openrouter', model: 'gpt-6.1-sol'),
          for (var i = 0; i < 25; i++)
            ModelChoice(provider: active.provider, model: 'codex-$i'),
          active,
        ];
        ModelSelection selected = const ModelSelection.model(active);
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(Brightness.dark),
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, update) => ModelChooser(
                  choices: choices,
                  selected: selected,
                  onSelected: (value) => update(() => selected = value),
                  scopeLabel: 'Chat models',
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final row = find.byKey(const Key('model-openai-codex-gpt-6.1-sol'));
        expect(row.hitTestable(), findsOneWidget);
        expect(
          find.byKey(const Key('model-openrouter-gpt-6.1-sol')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('model-provider-openai-codex')),
          findsNothing,
        );
        final tab = find.byKey(const Key('model-filter-openai-codex'));
        expect(tab.hitTestable(), findsOneWidget);
        expect(tester.getSemantics(tab), isSemantics(isSelected: true));
        expect(tester.getSemantics(row), isSemantics(isSelected: true));

        await tester.tap(find.byKey(const Key('model-filter-all')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('model-openrouter-other-0')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('model-openrouter-other-44')),
          findsNothing,
        );
        expect(selected.choice, active);
        await tester.enterText(
          find.byKey(const Key('model-search')),
          'gpt-6.1-sol',
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('model-openrouter-gpt-6.1-sol')),
          findsOneWidget,
        );
        expect(row, findsOneWidget);
        await tester.tap(find.byKey(const Key('model-openrouter-gpt-6.1-sol')));
        await tester.pumpAndSettle();
        expect(selected.choice?.provider, 'openrouter');
        expect(selected.choice?.model, active.model);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'duplicate IDs keep provider identity and a failed refresh keeps the draft',
    (tester) async {
      ModelSelection selected = const ModelSelection.model(first);
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => SizedBox(
                height: 600,
                child: ModelChooser(
                  choices: const [first, second],
                  selected: selected,
                  onSelected: (value) => update(() => selected = value),
                  onRefresh: () async => throw StateError('offline'),
                  scopeLabel: 'Models for test profile',
                ),
              ),
            ),
          ),
        ),
      );

      await tester.enterText(find.byKey(const Key('model-search')), 'shared');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('model-alpha-shared')), findsOneWidget);
      expect(find.byKey(const Key('model-beta-shared')), findsOneWidget);
      await tester.tap(find.byKey(const Key('model-beta-shared')));
      await tester.pumpAndSettle();
      expect(selected.choice?.provider, 'beta');

      await tester.tap(find.byKey(const Key('refresh-models')));
      await tester.pumpAndSettle();
      expect(find.text('Refresh failed. Previous list shown.'), findsOneWidget);
      expect(find.byKey(const Key('model-beta-shared')), findsOneWidget);
      expect(selected.choice?.provider, 'beta');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('model-search')))
            .controller
            ?.text,
        'shared',
      );
    },
  );

  testWidgets(
    'refresh reveals matching groups and keeps a missing selection visible',
    (tester) async {
      ModelSelection selected = const ModelSelection.model(second);
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.light),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => SizedBox(
                height: 600,
                child: ModelChooser(
                  choices: const [first, second],
                  selected: selected,
                  onSelected: (value) => update(() => selected = value),
                  onRefresh: () async => const [
                    first,
                    ModelChoice(provider: 'gamma', model: 'new-model'),
                  ],
                  scopeLabel: 'Models for test profile',
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('refresh-models')));
      await tester.pumpAndSettle();
      expect(find.textContaining('availability unconfirmed'), findsOneWidget);
      expect(selected.choice?.provider, 'beta');

      await tester.enterText(
        find.byKey(const Key('model-search')),
        'new-model',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('model-gamma-new-model')), findsOneWidget);
      expect(selected.choice?.provider, 'beta');
    },
  );
}
