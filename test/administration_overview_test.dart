import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/administration_overview.dart';
import 'support/administration_fixture.dart';

void main() {
  test(
    'overview registries and nested observations cannot be changed by readers',
    () async {
      final fixture = AdministrationFixture();
      fixture.override = (_, _, _, _) async => {
        'memory': {'memory_enabled': true},
        'items': [
          {'value': 'confirmed'},
        ],
      };
      final overview = AdministrationOverview(fixture.server.profile('work'));
      addTearDown(overview.dispose);
      await overview.refresh(keys: {'config'});
      expect(() => overview.observations.clear(), throwsUnsupportedError);
      expect(
        () => overview.connectorChecks['invented'] = true,
        throwsUnsupportedError,
      );
      final data = overview.observations['config']!.data!;
      expect(() => data.clear(), throwsUnsupportedError);
      expect(
        () => (data['memory'] as Map)['memory_enabled'] = false,
        throwsUnsupportedError,
      );
      expect(() => (data['items'] as List).clear(), throwsUnsupportedError);
      expect(
        () => ((data['items'] as List).first as Map)['value'] = 'changed',
        throwsUnsupportedError,
      );
    },
  );

  test(
    'retained overview inputs and older snapshots do not alias refreshes',
    () async {
      final fixture = AdministrationFixture();
      final response = <String, dynamic>{
        'memory': {'memory_enabled': true},
      };
      final pending = Completer<Map<String, dynamic>>();
      var calls = 0;
      fixture.override = (_, _, _, _) async =>
          ++calls == 1 ? response : pending.future;
      final overview = AdministrationOverview(fixture.server.profile('work'));
      addTearDown(overview.dispose);
      await overview.refresh(keys: {'config'});
      final confirmed = overview.observations['config']!;
      (response['memory'] as Map)['memory_enabled'] = false;
      expect(confirmed.data!['memory']['memory_enabled'], true);
      final refresh = overview.refresh(keys: {'config'});
      expect(overview.observations['config']!.loading, isTrue);
      expect(confirmed.loading, isFalse);
      pending.complete({
        'memory': {'memory_enabled': false},
      });
      await refresh;
      expect(
        overview.observations['config']!.data!['memory']['memory_enabled'],
        false,
      );
      expect(confirmed.data!['memory']['memory_enabled'], true);
      expect(confirmed.error, isNull);
    },
  );

  test(
    'restored overview collections are independent of their input snapshot',
    () {
      final fixture = AdministrationFixture();
      final overview = AdministrationOverview(fixture.server.profile('work'));
      addTearDown(overview.dispose);
      final saved = <String, dynamic>{
        'observations': {
          'config': {
            'data': {
              'nested': [1],
            },
            'checkedAt': null,
            'error': null,
          },
        },
        'connectorChecks': {'example': true},
      };
      overview.restoreHealth(saved);
      saved['observations']['config']['data']['nested'].add(2);
      saved['connectorChecks']['example'] = false;
      expect(overview.observations['config']!.data!['nested'], [1]);
      expect(overview.connectorChecks, {'example': true});
      expect(() => overview.connectorChecks.clear(), throwsUnsupportedError);
    },
  );

  test('retired overview cannot start another transport read', () async {
    final fixture = AdministrationFixture();
    final overview = AdministrationOverview(fixture.server.profile('work'));
    overview.dispose();
    await overview.refresh();
    expect(fixture.requests, isEmpty);
  });
  test(
    'malformed model refresh retains the last confirmed selection',
    () async {
      final fixture = AdministrationFixture();
      var malformed = false;
      fixture.override = (_, path, _, _) async => {
        'provider': 'openai',
        'model': malformed ? ['invalid'] : 'gpt-5.6-sol',
      };
      final overview = AdministrationOverview(fixture.server.profile('work'));
      addTearDown(overview.dispose);
      await overview.refresh(keys: {'model'});
      final checked = overview.observations['model']!.checkedAt;
      malformed = true;
      await overview.refresh(keys: {'model'});
      expect(overview.observations['model']!.data!['model'], 'gpt-5.6-sol');
      expect(overview.observations['model']!.checkedAt, checked);
      expect(overview.observations['model']!.error, isNotNull);
      expect(overview.modelAccess.model!.model, 'gpt-5.6-sol');
      expect(overview.modelAccess.unavailable, isTrue);
      expect(overview.modelAccess.loading, isFalse);
    },
  );

  test(
    'independent reads retain good observations after a failed refresh',
    () async {
      final fixture = AdministrationFixture();
      var fail = false;
      fixture.override = (method, path, query, body) async {
        if (path == 'config') {
          if (fail) throw StateError('offline');
          return {
            'memory': {'memory_enabled': true},
          };
        }
        if (path == 'model/info') throw StateError('unavailable');
        if (path == 'providers/oauth') return {'providers': []};
        if (path == 'mcp/servers') return {'servers': []};
        return {'data': []};
      };
      final overview = AdministrationOverview(
        fixture.server.profile('personal'),
      );
      addTearDown(overview.dispose);
      await overview.refresh();
      final checked = overview.observations['config']!.checkedAt;
      expect(overview.observations['config']!.data, {
        'memory': {'memory_enabled': true},
      });
      expect(overview.observations['model']!.error, isNotNull);
      expect(overview.observations['skills']!.data, {'data': []});
      fail = true;
      await overview.refresh();
      expect(overview.observations['config']!.checkedAt, checked);
      expect(overview.observations['config']!.data, isNotNull);
      expect(overview.observations['config']!.error, isNotNull);
      expect(
        fixture.requests.every(
          (r) => r.$1 == 'GET' && r.$3['profile'] == 'personal',
        ),
        isTrue,
      );
    },
  );

  test(
    'targeted refresh does not reread unrelated profile observations',
    () async {
      final fixture = AdministrationFixture();
      final overview = AdministrationOverview(
        fixture.server.profile('personal'),
      );
      addTearDown(overview.dispose);
      await overview.refresh();
      final model = overview.observations['model']!.checkedAt;
      fixture.requests.clear();
      await overview.refresh(keys: {'config'});
      expect(fixture.requests.map((r) => r.$2), ['config']);
      expect(overview.observations['model']!.checkedAt, model);
    },
  );

  for (final retireBeforeCompletion in [false, true]) {
    test(
      retireBeforeCompletion
          ? 'retired overview ignores an older pending refresh'
          : 'newer overview remains authoritative when an older refresh finishes',
      () async {
        final fixture = AdministrationFixture();
        addTearDown(fixture.server.close);
        final pending = Completer<Map<String, dynamic>>();
        var reads = 0;
        fixture.override = (_, path, _, _) async {
          if (path == 'config') {
            if (++reads == 1) return pending.future;
            return {'version': 2};
          }
          if (path == 'providers/oauth') return {'providers': []};
          if (path == 'mcp/servers') return {'servers': []};
          return {'data': []};
        };
        final overview = AdministrationOverview(fixture.server.profile('work'));
        var retired = false;
        addTearDown(() {
          if (!retired) overview.dispose();
          if (!pending.isCompleted) pending.complete({'version': 1});
        });
        final old = overview.refresh();
        await overview.refresh();
        expect(overview.observations['config']!.data, {'version': 2});
        if (retireBeforeCompletion) {
          overview.dispose();
          retired = true;
        }
        pending.complete({'version': 1});
        await old;
        expect(overview.observations['config']!.data, {'version': 2});
      },
    );
  }

  test('malformed collection does not erase last confirmed data', () async {
    final fixture = AdministrationFixture();
    var malformed = false;
    fixture.override = (_, path, _, _) async => switch (path) {
      'skills' => {
        'data': malformed
            ? 'invalid'
            : [
                {'name': 'research', 'enabled': true},
              ],
      },
      'providers/oauth' => {'providers': []},
      'mcp/servers' => {'servers': []},
      _ => {'data': []},
    };
    final overview = AdministrationOverview(fixture.server.profile('work'));
    addTearDown(overview.dispose);
    await overview.refresh();
    malformed = true;
    await overview.refresh();
    expect(overview.observations['skills']!.data!['data'], isList);
    expect(overview.observations['skills']!.error, isNotNull);
  });
}
