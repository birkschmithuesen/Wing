import 'package:wing/core/models/app_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/theme/wing_icons.dart';
import 'package:wing/core/widgets/composer_action_settings.dart';

void main() {
  testWidgets('Steer is selected when no preference has been saved', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final owner = AppPreferences(await SharedPreferences.getInstance());
    addTearDown(owner.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ComposerActionSettings(preferences: owner)),
      ),
    );
    expect(
      find.descendant(
        of: find.widgetWithText(ChoiceChip, 'Steer'),
        matching: find.byIcon(WingIcons.steer),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.widgetWithText(ChoiceChip, 'Queue'),
        matching: find.byIcon(WingIcons.queue),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Steer'))
          .selected,
      isTrue,
    );
  });

  testWidgets('a chosen action survives reconstructing its preference owner', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    var owner = AppPreferences(preferences);
    addTearDown(() => owner.dispose());
    Future<void> show() => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ComposerActionSettings(preferences: owner)),
      ),
    );
    await show();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Queue'));
    await tester.pumpAndSettle();
    expect(
      preferences.getString(AppPreferenceField.runningAction.storageKey),
      'queue',
    );
    await tester.pumpWidget(const SizedBox());
    owner.dispose();
    owner = AppPreferences(await SharedPreferences.getInstance());
    await show();
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Queue'))
          .selected,
      isTrue,
    );
  });
}
