import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/retained_memory.dart';
import 'package:wing/core/services/retained_memory_session.dart';
import 'support/administration_fixture.dart';
import 'support/retained_memory_fixture.dart';

void main() {
  test(
    'catalog projects immutable supplied identities and preserves search across refresh',
    () async {
      final f = AdministrationFixture();
      f.override = (_, _, _, _) async => currentMemoryGraph();
      final owner = RetainedMemoryCatalogSession(f.server.profile('personal'));
      addTearDown(owner.dispose);
      await owner.refresh();
      owner.searchFor('SECOND');
      expect(
        owner.cards.single.identity.value,
        'memory:profile:1:222222222222',
      );
      expect(() => owner.reading.value!.cards.clear(), throwsUnsupportedError);
      await owner.refresh();
      expect(owner.search, 'SECOND');
      expect(owner.cards, hasLength(1));
      expect(
        f.requests.every((r) => r.$1 == 'GET' && r.$3['profile'] == 'personal'),
        true,
      );
    },
  );
  test(
    'malformed refreshed catalog retains prior reading and timestamp',
    () async {
      final f = AdministrationFixture();
      var malformed = false;
      f.override = (_, _, _, _) async => malformed
          ? {
              'memory': [],
              'nodes': [
                {'kind': 'memory'},
              ],
            }
          : currentMemoryGraph();
      final owner = RetainedMemoryCatalogSession(f.server.profile('personal'));
      addTearDown(owner.dispose);
      await owner.refresh();
      final old = owner.reading;
      malformed = true;
      await owner.refresh();
      expect(identical(owner.reading.value, old.value), true);
      expect(owner.reading.checkedAt, old.checkedAt);
      expect(owner.reading.error, isNotNull);
      expect(owner.reading.canRecover, false);
    },
  );
  test(
    'temporary refresh failure retains prior reading and enables only read recovery',
    () async {
      final f = AdministrationFixture();
      var unavailable = false;
      f.override = (_, _, _, _) async {
        if (unavailable) {
          throw TimeoutException('Read unavailable');
        }
        return currentMemoryGraph();
      };
      final owner = RetainedMemoryCatalogSession(f.server.profile('personal'));
      addTearDown(owner.dispose);
      await owner.refresh();
      final old = owner.reading.value;
      unavailable = true;
      await owner.refresh();
      expect(identical(owner.reading.value, old), true);
      expect(owner.reading.canRecover, true);
      unavailable = false;
      await owner.refresh();
      expect(owner.reading.error, isNull);
      expect(f.requests.every((r) => r.$1 == 'GET'), true);
    },
  );
  test('newer catalog completion owns reading over held prior read', () async {
    final f = AdministrationFixture();
    final held = Completer<Map<String, dynamic>>();
    var calls = 0;
    f.override = (_, _, _, _) async =>
        ++calls == 1 ? held.future : currentMemoryGraph();
    final owner = RetainedMemoryCatalogSession(f.server.profile('personal'));
    addTearDown(owner.dispose);
    final old = owner.refresh();
    await owner.refresh();
    final current = owner.reading.value;
    held.complete({'memory': [], 'nodes': []});
    await old;
    expect(identical(owner.reading.value, current), true);
    expect(owner.cards, hasLength(2));
  });
  test(
    'reentrant newer loading request supersedes old request before its read',
    () async {
      final f = AdministrationFixture();
      f.override = (_, _, _, _) async => currentMemoryGraph();
      final owner = RetainedMemoryCatalogSession(f.server.profile('personal'));
      addTearDown(owner.dispose);
      var replaced = false;
      Future<void>? newer;
      owner.addListener(() {
        if (!replaced) {
          replaced = true;
          newer = owner.refresh();
        }
      });
      await owner.refresh();
      await newer;
      expect(f.requests, hasLength(1));
      expect(owner.cards, hasLength(2));
    },
  );
  test(
    'retired read drains captured lease without publication or further requests',
    () async {
      final f = AdministrationFixture();
      final held = Completer<Map<String, dynamic>>();
      f.override = (_, _, _, _) async => held.future;
      final owner = RetainedMemoryCatalogSession(f.server.profile('personal'));
      var notifications = 0;
      owner.addListener(() => notifications++);
      final work = owner.refresh();
      owner.dispose();
      f.server.close();
      final before = notifications;
      held.complete(currentMemoryGraph());
      await work;
      expect(owner.reading.value, isNull);
      expect(notifications, before);
      final count = f.requests.length;
      await owner.refresh();
      owner.searchFor('second');
      expect(f.requests.length, count);
      expect(owner.search, isEmpty);
    },
  );
  test(
    'detail captures exact graph identity and profile; no write capability is exposed',
    () async {
      final f = AdministrationFixture();
      final identity = RetainedMemoryIdentity.fromWire(
        'memory:profile:1:222222222222',
      );
      f.override = (method, path, query, body) async {
        expect(method, 'GET');
        expect(path, 'learning/node');
        expect(query, {'profile': 'personal', 'id': identity.value});
        return currentMemoryDetail(identity.value);
      };
      final owner = RetainedMemoryDetailSession(
        f.server.profile('personal'),
        identity,
      );
      addTearDown(owner.dispose);
      await owner.refresh();
      expect(owner.reading.value!.content, 'Full second memory');
      expect(identical(owner.reading.value!.identity, identity), true);
    },
  );
  test(
    'wrong detail identity or kind retains previous exact reading',
    () async {
      final f = AdministrationFixture();
      final identity = RetainedMemoryIdentity.fromWire(
        'memory:profile:1:222222222222',
      );
      var response = currentMemoryDetail(identity.value);
      f.override = (_, _, _, _) async => response;
      final owner = RetainedMemoryDetailSession(
        f.server.profile('personal'),
        identity,
      );
      addTearDown(owner.dispose);
      await owner.refresh();
      final old = owner.reading.value;
      response = {...response, 'id': 'memory:profile:0:222222222222'};
      await owner.refresh();
      expect(identical(owner.reading.value, old), true);
      response = {...response, 'id': identity.value, 'kind': 'skill'};
      await owner.refresh();
      expect(identical(owner.reading.value, old), true);
      expect(owner.reading.error, isNotNull);
      expect(owner.reading.canRecover, false);
    },
  );
  test(
    'retired detail cannot publish late result or start another read',
    () async {
      final f = AdministrationFixture();
      final held = Completer<Map<String, dynamic>>();
      f.override = (_, _, _, _) async => held.future;
      final identity = RetainedMemoryIdentity.fromWire(
        'memory:profile:1:222222222222',
      );
      final owner = RetainedMemoryDetailSession(
        f.server.profile('personal'),
        identity,
      );
      final read = owner.refresh();
      owner.dispose();
      held.complete(currentMemoryDetail(identity.value));
      await read;
      expect(owner.reading.value, isNull);
      await owner.refresh();
      expect(f.requests, hasLength(1));
    },
  );
}
