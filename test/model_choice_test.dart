import 'package:wing/core/models/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/model_choice.dart';
import 'package:wing/core/models/chat_intelligence.dart';

void main() {
  test('route changes retain only the supplied fast tier', () {
    final routes = ModelCatalog.fromOptions({
      'providers': [
        {
          'slug': 'route',
          'name': 'Route',
          'models': ['ultra', 'fast', 'normal'],
          'capabilities': {
            'ultra': {'fast': true, 'ultrafast': true},
            'fast': {'fast': true},
            'normal': {'fast': false},
          },
        },
      ],
    }).choices;
    final draft = ChatIntelligenceSelection(
      choice: routes[0],
      reasoningEffort: 'high',
      fastMode: ChatFastMode.ultrafast,
    );
    expect(draft.withChoice(routes[0]).fastMode, ChatFastMode.ultrafast);
    expect(draft.withChoice(routes[1]).fastMode, ChatFastMode.fast);
    expect(draft.withChoice(routes[2]).fastMode, ChatFastMode.normal);
  });
  test(
    'current catalog rows preserve provider identity and string model IDs',
    () {
      final choices = ModelCatalog.fromOptions({
        'providers': [
          {
            'slug': 'built-in',
            'name': 'Built in',
            'models': ['same'],
          },
          {
            'slug': 'custom:office',
            'name': 'Office',
            'models': ['same'],
          },
          {
            'slug': 'llamacpp',
            'name': 'Local',
            'models': ['local-model'],
          },
          {
            'slug': 'moa',
            'name': 'Mixture of Agents',
            'models': ['review'],
          },
          {'slug': 'unconfigured', 'name': 'Not configured', 'models': []},
        ],
      }).choices;
      expect(choices.map((choice) => choice.provider), [
        'built-in',
        'custom:office',
        'llamacpp',
        'moa',
      ]);
      expect(choices.map((choice) => choice.model), [
        'same',
        'same',
        'local-model',
        'review',
      ]);
      expect(choices[1].routeLabel, 'Office');
      expect(
        ModelSelection.model(choices[0]),
        isNot(ModelSelection.model(choices[1])),
      );
    },
  );

  test('display metadata cannot change route equality', () {
    const original = ModelSelection.model(
      ModelChoice(provider: 'route', model: 'id'),
    );
    const renamed = ModelSelection.model(
      ModelChoice(
        provider: 'route',
        model: 'id',
        providerLabel: 'New label',
        displayName: 'Friendly',
      ),
    );
    expect(renamed, original);
    expect(renamed.hashCode, original.hashCode);
    expect(renamed.choice!.label, 'Friendly');
    expect(
      original,
      isNot(const ModelSelection.special(ModelSpecialChoice.automatic)),
    );
  });

  test('unsupported aliases and non-string wire values are rejected', () {
    final rows = [
      {
        'id': 'route',
        'name': 'Route',
        'models': ['m'],
      },
      {
        'slug': 'route',
        'display_name': 'Route',
        'models': ['m'],
      },
      {
        'slug': 'route',
        'title': 'Route',
        'models': ['m'],
      },
      for (final alias in ['id', 'model', 'name'])
        {
          'slug': 'route',
          'name': 'Route',
          'models': [
            {alias: 'm'},
          ],
        },
      {
        'slug': 42,
        'name': 'Route',
        'models': ['m'],
      },
      {
        'slug': 'route',
        'name': 42,
        'models': ['m'],
      },
      {
        'slug': 'route',
        'name': 'Route',
        'models': [42],
      },
      {
        'slug': ' ',
        'name': 'Route',
        'models': ['m'],
      },
      {
        'slug': 'route',
        'name': 'Route',
        'models': [' '],
      },
      {'slug': 'route', 'name': 'Route', 'models': 'm'},
    ];
    for (final row in rows) {
      expect(
        () => ModelCatalog.fromOptions({
          'providers': [row],
        }).choices,
        throwsFormatException,
      );
    }
    for (final value in [
      null,
      'providers',
      [true],
    ]) {
      expect(
        () => ModelCatalog.fromOptions({'providers': value}).choices,
        throwsFormatException,
      );
    }
  });
}
