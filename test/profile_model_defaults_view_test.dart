import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/administration/admin_defaults_page.dart';

import 'support/model_defaults_fixture.dart';

void main() {
  testWidgets(
    'helper picker cannot overwrite an endpoint changed while it is open',
    (tester) async {
      final fixture = ModelDefaultsFixture();
      await tester.pumpWidget(
        MaterialApp(
          home: AdminDefaultsPage(profile: fixture.server.profile('personal')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('vision'));
      await tester.tap(find.text('vision'));
      await tester.pumpAndSettle();
      // This route-visible field was never represented in the former pending
      // ModelSelection. The server value changes after opening, before Apply.
      fixture.vision['base_url'] = 'https://external.invalid';
      await tester.tap(find.byKey(const Key('admin-model-p-after')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Set helper model'));
      await tester.pumpAndSettle();
      expect(fixture.posts, isEmpty);
      expect(fixture.vision['model'], 'before');
      expect(find.textContaining('changed elsewhere'), findsOneWidget);
      expect(find.text('Pending: p / after'), findsOneWidget);
      expect(find.byTooltip('Discard pending helper change'), findsOneWidget);
    },
  );
}
