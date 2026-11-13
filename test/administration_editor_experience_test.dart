import 'package:wing/core/models/settings_edit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/administration/admin_settings_page.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'support/administration_fixture.dart';

void main() {
  test(
    'percentage formatting shifts exact decimal text in both directions',
    () {
      expect(shiftDecimal('0.29', 2), '29');
      expect(shiftDecimal('29', -2), '0.29');
      expect(shiftDecimal('0.8123456789', 2), '81.23456789');
      expect(shiftDecimal('.5', -2), '0.005');
      expect(shiftDecimal('1e-3', 2), '0.1');
      expect(
        shiftDecimal('1e999999999999999999999999', 2),
        '1e999999999999999999999999',
      );
    },
  );

  testWidgets(
    'conflict resolution retains draft and catches a second remote change',
    (tester) async {
      final fixture = AdministrationFixture();
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.light),
          home: AdminSettingsPage(
            profile: fixture.server.profile('personal'),
            title: 'Memory settings',
            fields: [memoryFields[2]],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '2500');
      await tester.pump();
      (fixture.configs['personal']!['memory'] as Map)['memory_char_limit'] =
          4000;
      await tester.tap(find.byTooltip('Save changes'));
      await tester.pumpAndSettle();
      expect(find.text('Current server value: 4000'), findsOneWidget);
      expect(fixture.requests.where((r) => r.$1 == 'PUT'), isEmpty);
      await tester.ensureVisible(find.text('Keep my value'));
      await tester.tap(find.text('Keep my value'));
      await tester.pumpAndSettle();
      (fixture.configs['personal']!['memory'] as Map)['memory_char_limit'] =
          5000;
      await tester.tap(find.byTooltip('Save changes'));
      await tester.pumpAndSettle();
      expect(find.text('Current server value: 5000'), findsOneWidget);
      expect(fixture.requests.where((r) => r.$1 == 'PUT'), isEmpty);
      await tester.ensureVisible(find.text('Use server value'));
      await tester.tap(find.text('Use server value'));
      await tester.pumpAndSettle();
      expect(find.text('5000'), findsOneWidget);
      expect(find.text('No unsaved changes'), findsOneWidget);
    },
  );

  testWidgets(
    'field search scrolls to target without opening the keyboard at 200 percent',
    (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fixture = AdministrationFixture();
      fixture.configs['personal']!['delegation'] = {
        'max_iterations': 10,
        'max_concurrent_children': 3,
        'max_spawn_depth': 2,
        'child_timeout_seconds': 120,
      };
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: AdminSettingsPage(
            profile: fixture.server.profile('personal'),
            title: 'Execution',
            fields: executionFields,
            initialField: 'delegation.child_timeout_seconds',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      expect(
        find
            .byKey(const ValueKey('setting:delegation.child_timeout_seconds'))
            .hitTestable(),
        findsOneWidget,
      );
      expect(tester.testTextInput.isVisible, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
