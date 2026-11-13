import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hosted_connector_accounts.dart';
import 'package:wing/core/services/hosted_connector_accounts_session.dart';
import 'package:wing/core/services/ws_client.dart';
import 'support/hosted_connector_fixture.dart';

void main() {
  late HostedConnectorFixture fixture;
  late HostedConnectorAccountsSession session;
  setUp(() {
    fixture = HostedConnectorFixture();
    session = HostedConnectorAccountsSession(
      fixture.server.profile('personal'),
    );
  });
  tearDown(() {
    session.dispose();
  });

  test(
    'catalog reads do not mint identity; rename captures exact account and profile',
    () async {
      await session.refresh();
      expect(fixture.calls.map((call) => call.$1), [
        'connectors.catalog',
        'connectors.accounts',
      ]);
      expect(
        await session.rename(session.accounts.first, 'work-calendar'),
        isTrue,
      );
      final call = fixture.calls.singleWhere(
        (call) => call.$1 == 'connectors.accounts.rename',
      );
      expect(call.$2, {
        'profile': 'personal',
        'connection_id': 'work-id',
        'alias': 'work-calendar',
      });
      expect(session.accounts.map((row) => row.alias), [
        'work-calendar',
        'personal',
      ]);
    },
  );
  test(
    'reconnect binds exact existing ID without creating alias; old snapshots cannot regress',
    () async {
      await session.refresh();
      expect(
        await session.connect(
          session.catalog.single,
          reconnect: session.accounts.last,
        ),
        isTrue,
      );
      final call = fixture.calls.singleWhere(
        (call) => call.$1 == 'connectors.connect',
      );
      expect(call.$2, {
        'profile': 'personal',
        'owner': {'type': 'account'},
        'connectors': ['calendar'],
        'reconnect': true,
        'connection_id': 'personal-id',
      });
      fixture.sequence = 0;
      await session.checkAuthorization();
      expect(session.operation!.sequence, 1);
      fixture.sequence = 2;
      fixture.settled = true;
      await session.checkAuthorization();
      expect(session.operation!.settled, isTrue);
    },
  );
  test(
    'uncertain mutation blocks repeated writes until explicit observation',
    () async {
      await session.refresh();
      final account = session.accounts.first;
      fixture.failMutation = true;
      expect(await session.rename(account, 'new-name'), isFalse);
      expect(session.canMutate, isFalse);
      expect(await session.rename(account, 'new-name'), isFalse);
      expect(
        fixture.calls.where((call) => call.$1 == 'connectors.accounts.rename'),
        hasLength(1),
      );
      fixture.failMutation = false;
      await session.refresh();
      expect(session.canMutate, isTrue);
      expect(session.accounts.first.alias, 'work');
    },
  );
  for (final operation in ['rename', 'remove']) {
    test(
      '$operation acknowledgement requires matching account readback',
      () async {
        await session.refresh();
        final account = session.accounts.first;
        final before = [
          for (final row in fixture.accounts) Map<String, dynamic>.of(row),
        ];
        fixture.rpcOverride = (method, params) async {
          if (method == 'connectors.accounts') return {'accounts': before};
          return fixture.rpc(method, params);
        };
        final confirmed = operation == 'rename'
            ? await session.rename(account, 'new-name')
            : await session.remove(account);
        expect(confirmed, isFalse);
        expect(session.error, contains('could not be confirmed'));
        expect(session.accounts.first.alias, 'work');
        expect(session.canMutate, isFalse);
        expect(
          fixture.calls.where(
            (call) => call.$1 == 'connectors.accounts.$operation',
          ),
          hasLength(1),
        );
        fixture.rpcOverride = fixture.rpc;
        await session.refresh();
        expect(session.canMutate, isTrue);
        expect(
          session.accounts.any(
            (row) => row.id == account.id && row.alias == 'work',
          ),
          isFalse,
        );
      },
    );
  }

  test('disposal during held profile preflight never dispatches', () async {
    await session.refresh();
    final gate = Completer<Map<String, dynamic>>();
    final entered = Completer<void>();
    fixture.override = (method, path, query, body) async {
      if (path == 'profiles') {
        entered.complete();
        return gate.future;
      }
      return {'current': 'personal'};
    };
    final pending = session.remove(session.accounts.first);
    await entered.future;
    session.dispose();
    gate.complete({
      'profiles': [
        {'name': 'personal'},
      ],
    });
    expect(await pending, isFalse);
    expect(
      fixture.calls.where((call) => call.$1 == 'connectors.accounts.remove'),
      isEmpty,
    );
  });
  test('malicious sign-in schemes are never exposed as launchable links', () {
    final operation = fixture.operation();
    (operation['targets'] as List).first['connect_url'] = 'javascript:alert(1)';
    expect(
      HostedConnectionOperation.fromJson(operation).targets.single.connectUrl,
      isNull,
    );
  });
  test(
    'known alias rejection keeps the editable account usable without a refresh gate',
    () async {
      await session.refresh();
      fixture.rpcOverride = (method, params) async {
        if (method == 'connectors.accounts.rename') {
          throw JsonRpcError(
            method,
            'That name is already used.',
            reason: 'ALIAS_TAKEN',
          );
        }
        return fixture.rpc(method, params);
      };
      expect(await session.rename(session.accounts.first, 'personal'), isFalse);
      expect(session.canMutate, isTrue);
      expect(session.error, contains('Choose another name'));
      fixture.rpcOverride = fixture.rpc;
      expect(await session.rename(session.accounts.first, 'work-new'), isTrue);
    },
  );
}
