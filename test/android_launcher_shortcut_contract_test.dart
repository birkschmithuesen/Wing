import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'all launcher shortcuts publish distinct actions for MainActivity',
    () async {
      final template = await File(
        'android/app/src/main/shortcuts.xml.template',
      ).readAsString();
      final manifest = await File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsString();
      final activity = await File(
        'android/app/src/main/kotlin/com/tarkilhk/wing/MainActivity.kt',
      ).readAsString();
      final shortcuts = RegExp(
        r'<shortcut\s[\s\S]*?</shortcut>',
      ).allMatches(template).map((match) => match.group(0)!).toList();
      const actions = {
        'new_quick_chat': 'QUICK_CHAT',
        'activity': 'ACTIVITY',
        'search_chats': 'SEARCH_CHATS',
      };
      expect(shortcuts, hasLength(actions.length));
      for (final entry in actions.entries) {
        final shortcut = shortcuts.singleWhere(
          (xml) => xml.contains('android:shortcutId="${entry.key}"'),
        );
        expect(shortcut, contains('android:targetPackage="@APPLICATION_ID@"'));
        expect(
          shortcut,
          contains('android:targetClass="com.tarkilhk.wing.MainActivity"'),
        );
        final action = 'com.tarkilhk.wing.action.${entry.value}';
        expect(shortcut, contains(action));
        expect(manifest, contains(action));
        expect(activity, contains(action));
      }
    },
  );

  test('Android publishes a static New Quick Chat launcher shortcut', () async {
    final manifest = await File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsString();
    final shortcuts = await File(
      'android/app/src/main/shortcuts.xml.template',
    ).readAsString();

    expect(manifest, contains('android.app.shortcuts'));
    expect(manifest, contains('@xml/shortcuts'));
    expect(shortcuts, contains('android:shortcutId="new_quick_chat"'));
    expect(shortcuts, contains('android:targetPackage="@APPLICATION_ID@"'));
    expect(
      shortcuts,
      contains('android:targetClass="com.tarkilhk.wing.MainActivity"'),
    );
    expect(shortcuts, contains('com.tarkilhk.wing.action.QUICK_CHAT'));
  });

  test(
    'Wing release, development and performance QA use distinct application IDs',
    () async {
      final gradle = await File('android/app/build.gradle.kts').readAsString();
      expect(
        gradle,
        contains('variant.applicationId.set("com.tarkilhk.wing")'),
      );
      expect(gradle, contains('manifestPlaceholders["appLabel"] = "Wing"'));
      expect(gradle, contains('else ".dev"'));
      expect(gradle, contains('applicationIdSuffix = ".perfqa"'));
      expect(
        gradle,
        contains('manifestPlaceholders["appLabel"] = "Wing Perf QA"'),
      );
      expect(gradle, contains('applicationId.set(variant.applicationId)'));
      expect(gradle, contains('addGeneratedSourceDirectory'));
      expect(gradle, isNot(contains('wing_application_id')));
    },
  );

  test('MainActivity forwards cold and warm shortcut launches', () async {
    final source = await File(
      'android/app/src/main/kotlin/com/tarkilhk/wing/MainActivity.kt',
    ).readAsString();

    expect(source, contains('getInitialLaunchAction'));
    expect(source, contains('launchAction'));
    expect(source, contains('QUICK_CHAT'));
  });
}
