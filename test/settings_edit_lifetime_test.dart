import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/administration/admin_settings_page.dart';
import 'package:wing/core/models/settings_edit.dart';
import 'support/administration_fixture.dart';

void main() {
  testWidgets(
    'retired settings route cannot dispatch after held preflight config',
    (tester) async {
      final fixture = AdministrationFixture();
      final held = Completer<Map<String, dynamic>>();
      var configs = 0;
      fixture.override = (method, path, query, body) async {
        if (method == 'GET' && path == 'config' && ++configs == 2) {
          return held.future;
        }
        final handler = fixture.override;
        fixture.override = null;
        try {
          return await fixture.send(method, path, query, body);
        } finally {
          fixture.override = handler;
        }
      };
      await tester.pumpWidget(
        MaterialApp(
          home: AdminSettingsPage(
            profile: fixture.server.profile('personal'),
            title: 'Memory',
            fields: [memoryFields[2]],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '2500');
      await tester.pump();
      await tester.tap(find.byTooltip('Save changes'));
      await tester.pump();
      expect(configs, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      held.complete({
        'memory': {'memory_enabled': true, 'memory_char_limit': 2000},
      });
      await tester.pumpAndSettle();
      expect(fixture.requests.where((request) => request.$1 == 'PUT'), isEmpty);
    },
  );
}
