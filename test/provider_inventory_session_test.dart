import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/provider_inventory.dart';
import 'package:wing/core/services/provider_inventory_session.dart';
import 'support/provider_edit_fixture.dart';

void main() {
  test(
    'one metadata observation supplies counts, search and environment owner policy',
    () async {
      final f = ProviderEditFixture();
      f.providers.add({
        'id': 'expired',
        'name': 'Expired',
        'flow': 'external',
        'status': {'logged_in': true, 'expires_at': '2020-01-01T00:00:00Z'},
      });
      f.env.addAll({
        'CHANNEL_KEY': ProviderEditFixture.field(isSet: true, managed: true),
        'CUSTOM_KEY': ProviderEditFixture.field(
          isSet: true,
          category: 'custom',
        ),
        'STORED_KEY': ProviderEditFixture.field(isSet: true, label: 'Stored'),
      });
      final owner = ProviderInventorySession(
        f.server.profile('personal'),
        scope: ProviderInventoryScope.inventory,
      );
      addTearDown(owner.dispose);
      await owner.refresh();
      expect(owner.observation!.count(ProviderInventoryFilter.attention), 1);
      expect(owner.providers.first.id, 'expired');
      expect(owner.keys.map((k) => k.key), ['STORED_KEY']);
      owner.search('example');
      expect(owner.keys.single.key, 'EXAMPLE_API_KEY');
      owner.search('');
      owner.selectFilter(ProviderInventoryFilter.stored);
      expect(owner.providers, isEmpty);
      expect(() => owner.observation!.keys.clear(), throwsUnsupportedError);
      expect(f.requests.every((r) => r.$1 == 'GET'), true);
    },
  );
  test('catalog owns only env reads and hides custom/channel keys', () async {
    final f = ProviderEditFixture();
    final owner = ProviderInventorySession(
      f.server.profile('personal'),
      scope: ProviderInventoryScope.catalog,
    );
    addTearDown(owner.dispose);
    await owner.refresh();
    expect(f.requests.map((r) => r.$2), ['env']);
    expect(owner.keys.single.key, 'EXAMPLE_API_KEY');
  });
  test(
    'malformed metadata refresh retains valid safe projection and timestamp',
    () async {
      final f = ProviderEditFixture();
      final owner = ProviderInventorySession(
        f.server.profile('personal'),
        scope: ProviderInventoryScope.inventory,
      );
      addTearDown(owner.dispose);
      await owner.refresh();
      final old = owner.observation;
      f.providers.first['id'] = 7;
      await owner.refresh();
      expect(identical(owner.observation, old), true);
      expect(owner.error, isNotNull);
      f.providers.first['id'] = 'provider';
      f.env['EXAMPLE_API_KEY'] = {'is_set': false};
      await owner.refresh();
      expect(identical(owner.observation, old), true);
      expect(owner.canRecover, false);
    },
  );
  test(
    'missing profile selections are independent from valid inventory',
    () async {
      final f = ProviderEditFixture()..failSelections = true;
      final owner = ProviderInventorySession(
        f.server.profile('personal'),
        scope: ProviderInventoryScope.inventory,
      );
      addTearDown(owner.dispose);
      await owner.refresh();
      expect(owner.observation!.selectionsAvailable, false);
      expect(owner.providers, hasLength(1));
    },
  );
  test(
    'late observation cannot publish and retired owner never rereads',
    () async {
      final f = ProviderEditFixture();
      final gate = Completer<void>();
      f.membershipGate = gate;
      final owner = ProviderInventorySession(
        f.server.profile('personal'),
        scope: ProviderInventoryScope.inventory,
      );
      final work = owner.refresh();
      await f.membershipEntered.future;
      owner.dispose();
      gate.complete();
      await work;
      expect(owner.observation, isNull);
      final count = f.requests.length;
      await owner.refresh();
      expect(f.requests.length, count);
    },
  );
}
