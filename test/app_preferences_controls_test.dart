import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/models/composer_action.dart';
import 'package:wing/core/services/app_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppPreferences> open(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    final owner = AppPreferences(await SharedPreferences.getInstance());
    addTearDown(owner.dispose);
    return owner;
  }

  test(
    'invalid choices expose repair with no selected default or current authority',
    () async {
      final owner = await open({
        'theme_mode': 'wrong',
        'workspace_accent_v1': 'mint',
        'composer_running_action': 'fork',
        'completion_notifications': 7,
      });
      expect(owner.current.theme.selected, isNull);
      expect(owner.current.accent.selected, isNull);
      expect(owner.current.runningAction.selected, isNull);
      expect(owner.current.completedNotifications.selected, isNull);
      expect(owner.current.theme.notice, isNotNull);
      expect(owner.current.theme.choose, isNotNull);
      expect(owner.current.completedNotificationsAllowed, isFalse);
      expect(owner.current.preferredRunningAction, isNull);
      expect(owner.current.needsAppearanceRepair, isTrue);
      expect(
        await owner.current.theme.choose!(AppThemePreference.dark),
        isTrue,
      );
      expect(owner.current.theme.selected, AppThemePreference.dark);
      expect(owner.current.theme.notice, isNull);
      expect(owner.current.accent.selected, isNull);
      expect(owner.current.needsAppearanceRepair, isTrue);
    },
  );

  test(
    'unrelated invalid voice does not disable confirmed action or notification fields',
    () async {
      final owner = await open({'voice.input': 'wrong'});
      expect(owner.current.storageVerified, isFalse);
      expect(owner.current.completedNotificationsAllowed, isTrue);
      expect(owner.current.attentionNotificationsAllowed, isTrue);
      expect(owner.current.notificationPreviewsAllowed, isTrue);
      expect(owner.current.preferredRunningAction, ComposerAction.steer);
      expect(owner.current.runningAction.choose, isNotNull);
      expect(owner.current.needsAppearanceRepair, isFalse);
    },
  );

  test(
    'retained appearance remains display history with unselected invalid repair control',
    () async {
      final owner = await open({'theme_mode': 'dark'});
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('theme_mode', 'wrong');
      await owner.reload();
      expect(owner.current.values.theme, AppThemePreference.dark);
      expect(owner.current.theme.selected, isNull);
      expect(owner.current.theme.notice, isNotNull);
      expect(owner.current.needsAppearanceRepair, isTrue);
      expect(
        await owner.current.theme.choose!(AppThemePreference.light),
        isTrue,
      );
      expect(owner.current.needsAppearanceRepair, isFalse);
    },
  );

  test(
    'passive choice absorbs failure and publishes confirmed selection and retry',
    () async {
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = _FailedTheme();
      final prefs = await SharedPreferences.getInstance();
      final owner = AppPreferences(prefs);
      addTearDown(() {
        owner.dispose();
        SharedPreferences.setMockInitialValues({});
      });
      expect(
        await owner.current.theme.choose!(AppThemePreference.light),
        isFalse,
      );
      expect(owner.current.theme.selected, AppThemePreference.dark);
      expect(owner.current.theme.error, isNotNull);
      expect(owner.current.theme.choose, isNotNull);
      await owner.reload();
      expect(prefs.getString('theme_mode'), 'dark');
    },
  );
}

class _FailedTheme extends InMemorySharedPreferencesStore {
  _FailedTheme() : super.withData({'flutter.theme_mode': 'dark'});
  @override
  Future<bool> setValue(String valueType, String key, Object value) =>
      value == 'light'
      ? Future.value(false)
      : super.setValue(valueType, key, value);
}
