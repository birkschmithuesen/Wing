import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/profile_colors.dart';
import 'package:wing/core/services/profile_colors_session.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/theme/profile_colors.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/profile_selector.dart';

void main() {
  testWidgets('long press changes a profile color without selecting it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final owner = AppPreferences(preferences);
    addTearDown(owner.dispose);
    final colors = ProfileColorsSession(
      preferences: owner,
      connectionIdentity: 'connection-a',
    )..updateProfiles(['work', 'default']);
    addTearDown(colors.dispose);
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.light),
        home: Scaffold(
          body: ProfileSelector(
            profiles: const [
              HermesProfile(name: 'default'),
              HermesProfile(name: 'work', displayName: 'Work'),
            ],
            selectedProfile: 'default',
            onSelected: (name) => selected = name,
            createColors: () => ProfileColorsSession(
              preferences: owner,
              connectionIdentity: 'connection-a',
            ),
          ),
        ),
      ),
    );
    await tester.longPress(find.byKey(const ValueKey('profile-work')));
    await tester.pumpAndSettle();
    expect(selected, isNull);
    expect(find.text('Color for Work'), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-color-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-color-11')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('profile-color-8')));
    await tester.pumpAndSettle();
    expect(
      colors.state.value.profiles['work']!.selected,
      ProfileColorChoice.blue,
    );
    expect(selected, isNull);
    expect(desktopProfileSwatches.length, 12);

    await tester.longPress(find.byKey(const ValueKey('profile-work')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('profile-color-automatic')));
    await tester.pumpAndSettle();
    expect(
      colors.state.value.profiles['work']!.selected,
      ProfileColorChoice.automatic,
    );
    await tester.tap(find.byKey(const ValueKey('profile-work')));
    expect(selected, 'work');
  });

  test(
    'profile colors survive reopening and stay with their connection',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final owner = AppPreferences(preferences);
      addTearDown(owner.dispose);
      ProfileColorsSession reopen(String identity) {
        final session = ProfileColorsSession(
          preferences: owner,
          connectionIdentity: identity,
        )..updateProfiles(['work', 'default']);
        addTearDown(session.dispose);
        return session;
      }

      final first = reopen('connection-a');
      final choice = first.beginChoice('work')!;
      expect(await choice.choose(ProfileColorChoice.lime), isNull);
      choice.dispose();
      expect(
        reopen('connection-a').state.value.profiles['work']!.selected,
        ProfileColorChoice.lime,
      );
      expect(
        reopen('connection-b').state.value.profiles['work']!.selected,
        ProfileColorChoice.automatic,
      );
      expect(
        first.state.value.profiles['default']!.selected,
        ProfileColorChoice.automatic,
      );
      final automatic = first.beginChoice('work')!;
      expect(await automatic.choose(ProfileColorChoice.automatic), isNull);
      automatic.dispose();
      expect(
        reopen('connection-a').state.value.profiles['work']!.selected,
        ProfileColorChoice.automatic,
      );
    },
  );

  testWidgets('selected profile is visible without moving the enclosing page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final owner = AppPreferences(await SharedPreferences.getInstance());
    addTearDown(owner.dispose);
    ProfileColorsSession createColors() => ProfileColorsSession(
      preferences: owner,
      connectionIdentity: 'connection-a',
    );
    final page = ScrollController(initialScrollOffset: 100);
    addTearDown(page.dispose);
    final profiles = List.generate(
      12,
      (i) => HermesProfile(name: 'profile-$i'),
    );
    var selected = 'profile-11';
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.dark),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return SingleChildScrollView(
                controller: page,
                child: Column(
                  children: [
                    const SizedBox(height: 200),
                    ProfileSelector(
                      profiles: profiles,
                      createColors: createColors,
                      selectedProfile: selected,
                      onSelected: (_) {},
                    ),
                    const SizedBox(height: 800),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final name in ['profile-11', 'profile-0']) {
      update(() => selected = name);
      await tester.pumpAndSettle();
      final chip = find.byKey(ValueKey('profile-$name'));
      expect(chip.hitTestable(), findsOneWidget);
      final rect = tester.getRect(chip);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(320));
      expect(page.offset, 100);
    }
    expect(tester.takeException(), isNull);
  });
}
