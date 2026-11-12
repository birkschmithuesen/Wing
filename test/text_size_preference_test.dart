import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/theme/app_preferences_rendering.dart';
import 'package:wing/core/widgets/text_size_settings_card.dart';
import 'package:wing/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'profile_connection_identity_test.dart' show MemoryIdentityStore;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('System returns the exact OS scaler without a clamp or override', () {
    final osScaler = _NonlinearTextScaler();

    final result = AppTextSizePreference.system.applyTo(osScaler);

    expect(identical(result, osScaler), isTrue);
    expect(result.scale(16), 25);
  });

  test('explicit choices multiply each OS scale within documented limits', () {
    const base = TextScaler.linear(1.6);

    expect(AppTextSizePreference.small.multiplier, 0.90);
    expect(AppTextSizePreference.standard.multiplier, 1.0);
    expect(AppTextSizePreference.large.multiplier, 1.15);
    expect(AppTextSizePreference.extraLarge.multiplier, 1.30);
    expect(AppTextSizePreference.large.applyTo(base).scale(10), 18.4);
    expect(AppTextSizePreference.extraLarge.applyTo(base).scale(10), 20.8);
  });

  test(
    'persists the global non-secret preference independently of profiles',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final owner = AppPreferences(prefs);
      addTearDown(owner.dispose);

      await owner.setTextSize(AppTextSizePreference.extraLarge);

      expect(owner.current.values.textSize, AppTextSizePreference.extraLarge);
      expect(
        prefs.getString(AppPreferenceField.textSize.storageKey),
        AppTextSizePreference.extraLarge.storageValue,
      );
    },
  );

  testWidgets('picker has an accessible preview and persists a selected size', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final owner = AppPreferences(prefs);
    addTearDown(owner.dispose);
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TextSizeSettingsCard(preferences: owner)),
      ),
    );

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == 'Text size: System',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Text size'));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == 'Text size preview',
      ),
      findsOneWidget,
    );
    final extraLarge = find.text('Extra large');
    await tester.scrollUntilVisible(extraLarge, 200);
    await tester.tap(extraLarge);
    await tester.pumpAndSettle();

    expect(owner.current.values.textSize, AppTextSizePreference.extraLarge);
    expect(
      prefs.getString(AppPreferenceField.textSize.storageKey),
      AppTextSizePreference.extraLarge.storageValue,
    );
    semantics.dispose();
  });

  testWidgets('card remains usable on compact screens at 100 to 200 percent', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final owner = AppPreferences(prefs);
    addTearDown(owner.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    for (final scale in [1.0, 1.3, 1.6, 2.0]) {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: TextSizeSettingsCard(preferences: owner),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Text size'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('WingApp updates its inherited scaler immediately', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final owner = AppPreferences(prefs);
    addTearDown(owner.dispose);
    final manager = await ConnectionManager.create(
      prefs,
      credentialStore: MemoryIdentityStore(),
    );
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
        child: WingApp(connManager: manager, appPreferences: owner),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      MediaQuery.textScalerOf(
        tester.element(find.text('Your agent, with you')),
      ).scale(10),
      16,
    );

    await owner.setTextSize(AppTextSizePreference.extraLarge);
    await tester.pump();

    expect(
      MediaQuery.textScalerOf(
        tester.element(find.text('Your agent, with you')),
      ).scale(10),
      20.8,
    );
  });
}

class _NonlinearTextScaler extends TextScaler {
  @override
  double get textScaleFactor => 1.5;

  @override
  double scale(double fontSize) => fontSize < 20 ? fontSize + 9 : fontSize * 2;
}
