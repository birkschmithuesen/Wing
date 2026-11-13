import 'package:wing/core/widgets/studio_selection_tile.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/device_preference.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/widgets/composer_action_settings.dart';
import 'package:wing/core/widgets/text_size_settings_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/shared_preferences');
  late Map<String, Object> disk;
  Completer<bool>? pending;

  setUp(() {
    SharedPreferences.resetStatic();
    disk = {'flutter.${AppPreferenceField.runningAction.storageKey}': 'steer'};
    pending = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getAll') return Map<String, Object>.of(disk);
          final args = Map<String, Object?>.from(call.arguments as Map);
          final key = args['key']! as String;
          final operation = pending;
          pending = null;
          if (operation != null && !await operation.future) return false;
          if (call.method == 'remove') {
            disk.remove(key);
          } else {
            disk[key] = args['value']!;
          }
          return true;
        });
  });

  tearDown(() {
    SharedPreferences.resetStatic();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  for (final throwsError in [false, true]) {
    test(
      'failed write restores confirmed cache and disk (throws: $throwsError)',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final write = pending = Completer<bool>();
        final result = saveDevicePreference(
          prefs,
          AppPreferenceField.runningAction.storageKey,
          'queue',
        );
        final assertion = expectLater(result, throwsA(anything));
        if (throwsError) {
          write.completeError(PlatformException(code: 'unavailable'));
        } else {
          write.complete(false);
        }
        await assertion;
        expect(
          prefs.getString(AppPreferenceField.runningAction.storageKey),
          'steer',
        );
        await prefs.reload();
        expect(
          prefs.getString(AppPreferenceField.runningAction.storageKey),
          'steer',
        );
      },
    );
  }

  testWidgets(
    'composer keeps confirmed selection pending, after failure and reopening',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final owner = AppPreferences(prefs);
      addTearDown(owner.dispose);
      Future<void> show() => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ComposerActionSettings(preferences: owner)),
        ),
      );
      await show();
      final write = pending = Completer<bool>();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Queue'));
      await tester.pump();
      final steer = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'Steer'),
      );
      expect(steer.selected, isTrue);
      expect(steer.onSelected, isNull);
      write.complete(false);
      await tester.pumpAndSettle();
      expect(
        find.text('Could not save the default action. Please retry.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await show();
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Steer'))
            .selected,
        isTrue,
      );
    },
  );

  testWidgets('text-size failure keeps picker and confirmed radio selection', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final owner = AppPreferences(prefs);
    addTearDown(owner.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TextSizeSettingsCard(preferences: owner)),
      ),
    );
    await tester.tap(find.text('Text size'));
    await tester.pumpAndSettle();
    final write = pending = Completer<bool>();
    await tester.tap(find.text('Large'));
    await tester.pump();
    expect(
      tester
          .widget<StudioRadioTile<AppTextSizePreference>>(
            find.byType(StudioRadioTile<AppTextSizePreference>).first,
          )
          .enabled,
      isFalse,
    );
    write.complete(false);
    await tester.pumpAndSettle();
    expect(
      find.text('Could not save the text size. Please retry.'),
      findsOneWidget,
    );
    expect(find.text('Extra large'), findsOneWidget);
    expect(owner.current.values.textSize, AppTextSizePreference.system);
    expect(prefs.getString('app_text_size_preference'), isNull);
  });
}
