import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/administration/admin_memory_page.dart';
import 'support/administration_fixture.dart';
import 'support/retained_memory_fixture.dart';

void main() {
  testWidgets(
    'filtered memory detail uses actual fingerprinted graph identity',
    (tester) async {
      final f = AdministrationFixture();
      f.override = (method, path, query, body) async {
        expect(method, 'GET');
        expect(query['profile'], 'personal');
        if (path == 'learning/graph') {
          return currentMemoryGraph();
        }
        if (path == 'learning/node') {
          return {
            'ok': true,
            'kind': 'memory',
            'id': query['id'],
            'label': 'Second memory',
            'content': 'Full second memory',
          };
        }
        throw StateError('Unexpected memory operation');
      };
      await tester.pumpWidget(
        MaterialApp(
          home: AdminMemoryPage(profile: f.server.profile('personal')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'second');
      await tester.pump();
      expect(find.text('First memory'), findsNothing);
      await tester.tap(find.text('Second memory'));
      await tester.pumpAndSettle();
      final detail = f.requests.singleWhere((r) => r.$2 == 'learning/node');
      expect(detail.$3, {
        'profile': 'personal',
        'id': 'memory:profile:1:222222222222',
      });
      expect(find.text('Full second memory'), findsOneWidget);
      expect(f.requests.every((r) => r.$1 == 'GET'), true);
      expect(find.text('Delete'), findsNothing);
      expect(find.text('Edit'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'malformed refresh retains last valid memory reading and search',
    (tester) async {
      final f = AdministrationFixture();
      var malformed = false;
      f.override = (_, _, _, _) async =>
          malformed ? {'memory': 'broken', 'nodes': []} : currentMemoryGraph();
      await tester.pumpWidget(
        MaterialApp(
          home: AdminMemoryPage(profile: f.server.profile('personal')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'second');
      await tester.pump();
      malformed = true;
      await tester.tap(find.text('Refresh memories'));
      await tester.pumpAndSettle();
      expect(find.text('Second memory'), findsOneWidget);
      expect(find.text('First memory'), findsNothing);
      expect(find.textContaining('Last checked'), findsOneWidget);
      expect(find.text('No retained memories in this profile.'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
