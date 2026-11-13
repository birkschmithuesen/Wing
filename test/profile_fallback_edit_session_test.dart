import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/fallback_model.dart';
import 'package:wing/core/models/model_choice.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/profile_fallback_edit_session.dart';

class _Fixture {
  List<Object?> wire = [
    {'provider': 'p', 'model': 'one', 'base_url': 'https://example.invalid/v1'},
    {'provider': 'p', 'model': 'two'},
  ];
  Completer<void>? catalogGate;
  Completer<void>? discoveryGate;
  bool failConfig = false;
  bool acknowledgeOnly = false;
  int writes = 0;
  late final AdministrationRepository server = AdministrationRepository(
    ownedMutation:
        (method, path, query, body, canDispatch, onDispatched) async {
          if (!canDispatch()) throw StateError('Retired fallback write');
          onDispatched();
          return server.request(method, path, query, body);
        },
    settingsWrite: (_, _, _, _) async =>
        throw StateError('Unexpected settings write'),
    connectionId: 'test',
    connectionIdentity: 'fallback-owner',
    connectionLabel: 'Test',
    gateway: (_) => throw StateError('Unexpected gateway'),
    request: (method, path, query, body) async {
      if (path == 'profiles') {
        await discoveryGate?.future;
        return {
          'profiles': [
            {'name': 'default', 'is_default': true},
          ],
        };
      }
      if (path == 'profiles/active') {
        return {'current': 'default', 'active': 'default'};
      }
      expect(query['profile'], 'default');
      if (path == 'model/options') {
        await catalogGate?.future;
        return {
          'providers': [
            {
              'slug': 'p',
              'name': 'Provider',
              'models': ['one', 'two', 'three'],
            },
          ],
        };
      }
      if (path == 'config') {
        if (failConfig) throw StateError('Offline');
        if (method == 'PUT') {
          writes++;
          expect(body!['profile'], 'default');
          if (!acknowledgeOnly) {
            wire =
                jsonDecode(
                      jsonEncode((body['config'] as Map)['fallback_providers']),
                    )
                    as List;
          }
          return {'ok': true};
        }
        return {'fallback_providers': wire};
      }
      throw StateError(path);
    },
  );
  late final edit = ProfileFallbackEditSession(server.profile('default'));
}

void main() {
  test('wire routing is deeply frozen', () {
    final route = <String, Object?>{
      'provider': 'p',
      'model': 'one',
      'routing': {
        'headers': ['private'],
      },
    };
    final value = FallbackModel.fromWire(route);
    (route['routing'] as Map)['headers'] = ['changed'];
    expect((value.toWire()['routing'] as Map)['headers'], ['private']);
  });

  for (final invalid in [
    null,
    'p/one',
    3,
    {'provider': 'p'},
    {'provider': true, 'model': 'one'},
  ]) {
    test('canonical fallback rejects malformed row $invalid', () {
      expect(
        () => FallbackModel.fromConfig({
          'fallback_providers': [invalid],
        }),
        throwsFormatException,
      );
    });
  }

  test(
    'fallback catalogs are immutable on initial and refreshed reads',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.edit.dispose);
      await fixture.edit.load();
      for (final refresh in [false, true]) {
        final choices = await fixture.edit.catalog(refresh: refresh);
        expect(choices.map((choice) => choice.model), ['one', 'two', 'three']);
        expect(() => choices.clear(), throwsUnsupportedError);
        expect(
          () => choices[0] = const ModelChoice(
            provider: 'other',
            model: 'injected',
          ),
          throwsUnsupportedError,
        );
        expect(choices.map((choice) => choice.model), ['one', 'two', 'three']);
      }
      expect(fixture.writes, 0);
      expect(fixture.edit.rows!.map((row) => row.model), ['one', 'two']);
    },
  );

  test(
    'retained fallback picker choices reject mutation and survive refresh',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.edit.dispose);
      await fixture.edit.load();
      final draft = (await fixture.edit.prepareSelection(index: 1))!;
      final wanted = draft.choices.last;
      expect(draft.current!.model, 'two');
      expect(() => draft.choices.removeAt(0), throwsUnsupportedError);
      expect(
        () => draft.choices[0] = const ModelChoice(
          provider: 'other',
          model: 'injected',
        ),
        throwsUnsupportedError,
      );
      final refreshed = await fixture.edit.catalog(refresh: true);
      expect(() => refreshed.clear(), throwsUnsupportedError);
      expect(draft.choices.map((choice) => choice.model), [
        'one',
        'two',
        'three',
      ]);
      expect(identical(draft.choices.last, wanted), true);
      expect(fixture.writes, 0);
      await fixture.edit.select(wanted, draft: draft);
      expect(fixture.writes, 1);
      expect(fixture.edit.rows!.map((row) => row.model), ['one', 'three']);
      expect(
        fixture.edit.rows!.first.toWire()['base_url'],
        'https://example.invalid/v1',
      );
    },
  );

  test(
    'held catalog cannot retarget an index after an earlier row is removed',
    () async {
      final fixture = _Fixture();
      await fixture.edit.load();
      fixture.catalogGate = Completer<void>();
      final selection = fixture.edit.prepareSelection(index: 1);
      await Future<void>.delayed(Duration.zero);
      await fixture.edit.remove(0);
      fixture.catalogGate!.complete();
      expect(await selection, isNull);
      expect(fixture.writes, 1);
      expect(fixture.edit.rows!.single.model, 'two');
      fixture.edit.dispose();
    },
  );

  test(
    'picker result from an old row revision cannot overwrite a different row',
    () async {
      final fixture = _Fixture();
      await fixture.edit.load();
      final draft = (await fixture.edit.prepareSelection(index: 1))!;
      await fixture.edit.remove(0);
      await fixture.edit.select(
        const ModelChoice(provider: 'p', model: 'three'),
        draft: draft,
      );
      expect(fixture.writes, 1);
      expect(fixture.edit.rows!.single.model, 'two');
      expect(fixture.edit.error, contains('list changed'));
      fixture.edit.dispose();
    },
  );

  test('disposal during profile validation prevents config dispatch', () async {
    final fixture = _Fixture();
    await fixture.edit.load();
    fixture.discoveryGate = Completer<void>();
    final operation = fixture.edit.remove(0);
    await Future<void>.delayed(Duration.zero);
    fixture.edit.dispose();
    fixture.discoveryGate!.complete();
    await operation;
    expect(fixture.writes, 0);
  });

  test(
    'review read failure becomes retained owner error and never dispatches',
    () async {
      final fixture = _Fixture();
      await fixture.edit.load();
      fixture.wire = [
        {'provider': 'p', 'model': 'external'},
      ];
      await fixture.edit.remove(0);
      expect(fixture.edit.conflict, isTrue);
      fixture.failConfig = true;
      expect(await fixture.edit.reviewPending(), isNull);
      expect(fixture.edit.pending, isNotNull);
      expect(fixture.edit.error, contains('Could not load'));
      expect(fixture.writes, 0);
      fixture.edit.dispose();
    },
  );

  test(
    'unverified write cannot replace confirmed rows or erase pending edit',
    () async {
      final fixture = _Fixture()..acknowledgeOnly = true;
      await fixture.edit.load();
      await fixture.edit.remove(0);
      expect(fixture.edit.rows, hasLength(2));
      expect(fixture.edit.pending, hasLength(1));
      expect(fixture.edit.error, contains('Save not confirmed'));
      fixture.edit.dispose();
    },
  );
}
