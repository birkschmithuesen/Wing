import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/services/app_preferences.dart';

void main() {
  group('an owner constructed before the widget clock', () {
    late SharedPreferences preferences;
    late AppPreferences owner;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      preferences = await SharedPreferences.getInstance();
      owner = AppPreferences(preferences);
    });
    tearDown(() => owner.dispose());

    testWidgets(
      'owner constructed before widget clock settles a choice in the command clock',
      (tester) async {
        final choice = owner.setAccent(AppAccentPreference.iris);
        var completed = false;
        choice.then<void>((_) {
          completed = true;
        }, onError: (Object _, StackTrace _) {});
        expect(owner.current.accent.busy, isTrue);
        await tester.pump();
        expect(owner.current.accent.busy, isFalse);
        expect(completed, isTrue);
        expect(preferences.getString('workspace_accent_v1'), 'iris');
      },
    );

    test(
      'reentrant pending observation preserves accepted choice order',
      () async {
        Future<AppPreferenceSaveResult>? later;
        var observing = false;
        void observe() {
          if (!observing && owner.current.accent.busy) {
            observing = true;
            later = owner.setAccent(AppAccentPreference.gold);
          }
        }

        owner.state.addListener(observe);
        final first = owner.setAccent(AppAccentPreference.iris);
        expect(later, isNotNull);
        await first;
        await later;
        owner.state.removeListener(observe);
        expect(owner.current.accent.busy, isFalse);
        expect(preferences.getString('workspace_accent_v1'), 'gold');
        expect(owner.current.values.accent, AppAccentPreference.gold);
      },
    );
  });

  test(
    'newer reentrant choice is dispatched after the accepted pending choice',
    () async {
      SharedPreferences.resetStatic();
      final store = _RecordingStore();
      SharedPreferencesStorePlatform.instance = store;
      final preferences = await SharedPreferences.getInstance();
      final owner = AppPreferences(preferences);
      addTearDown(() {
        owner.dispose();
        SharedPreferences.setMockInitialValues({});
      });
      Future<AppPreferenceSaveResult>? later;
      var observing = false;
      void observe() {
        if (!observing && owner.current.accent.busy) {
          observing = true;
          later = owner.setAccent(AppAccentPreference.gold);
        }
      }

      owner.state.addListener(observe);
      final first = owner.setAccent(AppAccentPreference.iris);
      expect(later, isNotNull);
      await first;
      await later;
      owner.state.removeListener(observe);
      // These are platform setValue invocations, not owner/private queue counters.
      expect(store.accentWrites, ['iris', 'gold']);
      expect(owner.current.accent.busy, isFalse);
      expect(preferences.getString('workspace_accent_v1'), 'gold');
      expect(owner.current.values.accent, AppAccentPreference.gold);
    },
  );
}

class _RecordingStore extends InMemorySharedPreferencesStore {
  _RecordingStore() : super.empty();
  final accentWrites = <String>[];
  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (key == 'flutter.workspace_accent_v1') {
      accentWrites.add(value as String);
    }
    return super.setValue(valueType, key, value);
  }
}
