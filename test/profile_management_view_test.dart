import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wing/core/screens/administration/admin_profiles_page.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profiles_management_session.dart';

import 'support/administration_fixture.dart';

Map<String, dynamic> _roster(Iterable<String> names) => {
  'profiles': [
    for (final name in names)
      {'name': name, 'is_default': name == 'default', 'display_name': name},
  ],
};

Future<void> _show(WidgetTester tester, AdministrationRepository server) async {
  await tester.pumpWidget(
    MaterialApp(
      home: AdminProfilesPage(
        createSession: () => ProfilesManagementSession(
          server: server,
          openProfile: (_) async => true,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _create(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Create profile'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextFormField), 'studio');
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('profile-name-save')));
  await tester.pump();
}

Future<void> _manage(WidgetTester tester, String action) async {
  await tester.tap(find.byTooltip('Manage work'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(action));
  await tester.pumpAndSettle();
  if (action == 'Rename') {
    await tester.enterText(find.byType(TextFormField), 'studio');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('profile-name-save')));
    await tester.pumpAndSettle();
  }
  await tester.tap(
    action == 'Delete'
        ? find.byTooltip('Delete profile')
        : find.byTooltip('Rename'),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final create in [true, false]) {
    testWidgets(
      '${create ? 'create' : 'rename'} rejects acknowledgement naming a different existing profile',
      (tester) async {
        final fixture = AdministrationFixture();
        fixture.override = (method, path, query, body) async {
          if (method == 'GET' && path == 'profiles') {
            return _roster(['default', 'personal', 'work']);
          }
          if (method == 'GET' && path == 'profiles/active') {
            return {'current': 'default', 'active': 'work'};
          }
          expect(method, create ? 'POST' : 'PATCH');
          expect(path, create ? 'profiles' : 'profiles/work');
          expect(body?[create ? 'name' : 'new_name'], 'studio');
          return {'ok': true, 'name': 'personal', 'path': '/fixture/personal'};
        };
        await _show(tester, fixture.server);
        if (create) {
          await _create(tester);
          await tester.pumpAndSettle();
        } else {
          await _manage(tester, 'Rename');
        }
        expect(
          fixture.requests.where((request) => request.$1 != 'GET'),
          hasLength(1),
        );
        expect(
          find.text(
            create
                ? 'Profile created. Open it to configure access and defaults.'
                : 'Profile renamed.',
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.textContaining('could not be confirmed'),
          ),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets('delete retains the stock pending identity settlement outcome', (
    tester,
  ) async {
    final fixture = AdministrationFixture();
    var deleted = false;
    fixture.override = (method, path, query, body) async {
      if (method == 'GET' && path == 'profiles') {
        return _roster(['default', 'personal', if (!deleted) 'work']);
      }
      if (method == 'GET' && path == 'profiles/active') {
        return {'current': 'default', 'active': 'personal'};
      }
      expect(method, 'DELETE');
      expect(path, 'profiles/work');
      deleted = true;
      return {
        'ok': true,
        'path': '/fixture/work',
        'identity_settled': false,
        'settlement_pending': true,
        'retry_command': 'hermes profile delete work --yes',
      };
    };
    await _show(tester, fixture.server);
    await _manage(tester, 'Delete');
    expect(find.text('Profile deleted.'), findsNothing);
    expect(find.textContaining('identity cleanup'), findsOneWidget);
    expect(find.byTooltip('Manage work'), findsNothing);
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();
    expect(
      fixture.requests.where((request) => request.$1 == 'DELETE'),
      hasLength(1),
    );
  });

  testWidgets('a confirmed create survives failure to refresh the roster', (
    tester,
  ) async {
    final fixture = AdministrationFixture();
    var created = false;
    fixture.override = (method, path, query, body) async {
      if (method == 'GET' && path == 'profiles') {
        return _roster(['default', 'work', if (created) 'studio']);
      }
      if (method == 'GET' && path == 'profiles/active') {
        if (created) throw StateError('Fixture refresh unavailable');
        return {'current': 'default', 'active': 'work'};
      }
      expect(method, 'POST');
      expect(path, 'profiles');
      created = true;
      return {'ok': true, 'name': 'studio', 'path': '/fixture/studio'};
    };
    await _show(tester, fixture.server);
    await _create(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('Profile created.'), findsOneWidget);
    expect(find.textContaining('could not be confirmed'), findsNothing);
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();
    expect(
      fixture.requests.where((request) => request.$1 == 'POST'),
      hasLength(1),
    );
  });

  testWidgets(
    'retiring the profiles route during auth prevents create dispatch',
    (tester) async {
      final fixture = AdministrationFixture();
      final entered = Completer<void>();
      final held = Completer<http.Response>();
      var writes = 0;
      final client = DashboardClient(
        host: 'fixture.invalid',
        httpClient: MockClient((request) async {
          if (request.url.path == '/') {
            entered.complete();
            return held.future;
          }
          if (request.method == 'POST') {
            writes++;
            expect(request.url.path, '/api/profiles');
            return http.Response(
              '{"ok":true,"name":"studio","path":"/fixture/studio"}',
              200,
            );
          }
          return http.Response('{"profiles":[]}', 200);
        }),
      );
      addTearDown(client.close);
      final server = AdministrationRepository(
        connectionId: fixture.server.connectionId,
        connectionIdentity: fixture.server.connectionIdentity,
        connectionLabel: fixture.server.connectionLabel,
        gateway: fixture.server.gateway,
        settingsWrite: fixture.server.settingsWrite,
        ownedMutation: (method, path, query, body, canDispatch, onDispatched) =>
            client.apiWriteOwned(
              method,
              path,
              body: body,
              canDispatch: canDispatch,
              onDispatched: onDispatched,
            ),
        request: (method, path, query, body) => method == 'GET'
            ? fixture.send(method, path, query, body)
            : client.apiPost(path, body: body),
      );
      await _show(tester, server);
      await _create(tester);
      await entered.future;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        held.complete(
          http.Response(
            'window.__HERMES_SESSION_TOKEN__="fixture-token";',
            200,
          ),
        );
        await client.apiGet('profiles');
      });
      await tester.pumpAndSettle();
      expect(writes, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
