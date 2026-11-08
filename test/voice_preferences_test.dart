import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/services/android_voice.dart';
import 'package:wing/core/services/voice_preferences_session.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_select.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/widgets/voice_preferences_card.dart';
import 'support/voice_fixture.dart';

class _FailingStorage extends InMemorySharedPreferencesStore {
  _FailingStorage() : super.empty();
  bool failNext = true;
  @override
  Future<bool> setValue(String type, String key, Object value) {
    if (failNext) {
      failNext = false;
      return Future.value(false);
    }
    return super.setValue(type, key, value);
  }
}

class _HeldVoiceStorage extends InMemorySharedPreferencesStore {
  _HeldVoiceStorage() : super.empty();
  final release = Completer<bool>();
  bool hold = true;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (hold && key.endsWith('voice.live_subscription_voice')) {
      hold = false;
      if (!await release.future) return false;
    }
    return super.setValue(type, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const capture = bool.fromEnvironment('VOICE_REVIEW');
  const frame = Key('voice-settings-frame');
  setUpAll(() async {
    if (!capture) return;
    const path = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(entry.key)
        ..addFont(
          Future.value(
            ByteData.sublistView(
              File('$path/${entry.value}').readAsBytesSync(),
            ),
          ),
        );
      await loader.load();
    }
  });
  test(
    'live conversation billing choice persists and invalid values require repair',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final owner = AppPreferences(preferences);
      expect(owner.current.liveVoiceMode.selected, LiveVoiceMode.subscription);
      await owner.setLiveVoiceMode(LiveVoiceMode.api);
      await owner.reload();
      expect(owner.current.liveVoiceMode.selected, LiveVoiceMode.api);
      await preferences.setString('voice.live_mode', 'automatic');
      await owner.reload();
      expect(owner.current.liveVoiceMode.selected, isNull);
      expect(owner.current.liveVoiceMode.notice, isNotNull);
      await owner.setLiveVoiceMode(LiveVoiceMode.subscription);
      expect(owner.current.liveVoiceMode.selected, LiveVoiceMode.subscription);
      owner.dispose();
    },
  );

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(frame),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build/voice-review').createSync(recursive: true);
      await File(
        'build/voice-review/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'independent engines and Android voice settings survive reload',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final owner = AppPreferences(prefs);
      addTearDown(owner.dispose);
      expect(owner.current.values.voiceInput, AppVoiceProcessing.local);
      expect(owner.current.values.voiceOutput, AppVoiceProcessing.local);
      await owner.setVoiceInput(AppVoiceProcessing.hermes);
      await owner.setVoice('french');
      await owner.setVoiceLanguage('fr-FR');
      await owner.setVoiceRate(AppVoiceRate.slower);
      await owner.reload();
      final saved = owner.current.values;
      expect(saved.voiceInput, AppVoiceProcessing.hermes);
      expect(saved.voiceOutput, AppVoiceProcessing.local);
      expect(saved.voice, 'french');
      expect(saved.voiceLanguage, 'fr-FR');
      expect(saved.voiceRate, AppVoiceRate.slower);
    },
  );

  Future<void> show(
    WidgetTester tester,
    AppPreferences owner,
    VoiceDeviceFixture device, {
    Brightness brightness = Brightness.light,
    double scale = 1,
    VoidCallback? link,
  }) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: frame,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: wingTheme(brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: VoicePreferencesPage(
            createSession: () => VoicePreferencesSession(
              preferences: owner,
              device: device,
              hermesProfileLabel: 'Personal',
              openHermesSettings: link,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> selectHermes(WidgetTester tester, String label) async {
    final field = find.byWidgetPredicate(
      (widget) =>
          widget is StudioSelect<AppVoiceProcessing> && widget.label == label,
    );
    await tester.ensureVisible(field);
    await tester.tap(
      find.descendant(of: field, matching: find.byType(TextField)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hermes · server profile').hitTestable().last);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'GPT-Live voices persist separately through mode switches and reopen',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final owner = AppPreferences(prefs);
      final device = VoiceDeviceFixture();
      addTearDown(owner.dispose);
      addTearDown(device.stream.close);
      await show(tester, owner, device);
      Future<void> pick(String label) async {
        final field = find.byWidgetPredicate(
          (widget) =>
              widget is StudioSelect<String> &&
              widget.label == 'GPT-Live voice',
        );
        await tester.ensureVisible(field);
        await tester.tap(
          find.descendant(of: field, matching: find.byType(TextField)),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).hitTestable().last);
        await tester.pumpAndSettle();
      }

      await pick('Breeze');
      expect(owner.current.liveSubscriptionVoice.selected, 'breeze');
      await owner.setLiveVoiceMode(LiveVoiceMode.api);
      await tester.pumpAndSettle();
      await pick('Cedar');
      await owner.setLiveVoiceMode(LiveVoiceMode.subscription);
      await tester.pumpAndSettle();
      expect(find.text('Breeze'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      final reopened = AppPreferences(prefs);
      addTearDown(reopened.dispose);
      expect(reopened.current.liveSubscriptionVoice.selected, 'breeze');
      expect(reopened.current.liveApiVoice.selected, 'cedar');
      expect(reopened.current.values.voice, '');
    },
  );

  test(
    'invalid GPT-Live voices are explicit and repairable per mode',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('voice.live_api_voice', 'cove');
      final owner = AppPreferences(prefs);
      addTearDown(owner.dispose);
      expect(owner.current.liveApiVoice.selected, isNull);
      expect(owner.current.liveApiVoice.notice, isNotNull);
      expect(owner.current.liveSubscriptionVoice.selected, 'cove');
      await owner.setLiveApiVoice('cedar');
      await owner.reload();
      expect(owner.current.liveApiVoice.selected, 'cedar');
    },
  );

  testWidgets('GPT-Live choice shows saving, failure and retry', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 800);
    addTearDown(tester.view.reset);
    SharedPreferences.resetStatic();
    final storage = _HeldVoiceStorage();
    SharedPreferencesStorePlatform.instance = storage;
    final owner = AppPreferences(await SharedPreferences.getInstance());
    final device = VoiceDeviceFixture();
    addTearDown(owner.dispose);
    addTearDown(device.stream.close);
    await show(tester, owner, device);
    Future<void> chooseBreeze() async {
      final field = find.byWidgetPredicate(
        (w) => w is StudioSelect<String> && w.label == 'GPT-Live voice',
      );
      await tester.ensureVisible(field);
      await tester.tap(
        find.descendant(of: field, matching: find.byType(TextField)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Breeze').hitTestable().last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    await chooseBreeze();
    await tester.pump();
    await screenshot(tester, 'live-voice-saving');
    expect(
      find.byWidgetPredicate(
        (w) => w is StudioLoading && w.label == 'Saving voice settings',
      ),
      findsWidgets,
    );
    expect(owner.current.liveSubscriptionVoice.selected, 'cove');
    await screenshot(tester, 'live-voice-saving');
    storage.release.complete(false);
    await tester.pumpAndSettle();
    expect(
      find
          .text('Could not save this voice setting. Please retry.')
          .hitTestable(),
      findsOneWidget,
    );
    expect(owner.current.liveSubscriptionVoice.selected, 'cove');
    await screenshot(tester, 'live-voice-save-failed');
    await chooseBreeze();
    await tester.pumpAndSettle();
    expect(owner.current.liveSubscriptionVoice.selected, 'breeze');
    expect(
      find.text('Could not save this voice setting. Please retry.'),
      findsNothing,
    );
  });

  testWidgets('live conversation setting explicitly selects API billing', (
    tester,
  ) async {
    final owner = AppPreferences(await SharedPreferences.getInstance());
    final device = VoiceDeviceFixture();
    addTearDown(owner.dispose);
    addTearDown(device.stream.close);
    await show(tester, owner, device);
    final field = find.byWidgetPredicate(
      (widget) => widget is StudioSelect<LiveVoiceMode>,
    );
    await tester.tap(
      find.descendant(of: field, matching: find.byType(TextField)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('OpenAI API').hitTestable().last);
    await tester.pumpAndSettle();
    expect(owner.current.liveVoiceMode.selected, LiveVoiceMode.api);
    expect(find.textContaining('Voice usage is billed'), findsOneWidget);
    await screenshot(tester, 'live-api-choice');
  });

  testWidgets(
    'output selection persists; remote voice is a profile link, not a picker',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final owner = AppPreferences(prefs);
      addTearDown(owner.dispose);
      final device = VoiceDeviceFixture();
      var links = 0;
      addTearDown(device.stream.close);
      await show(tester, owner, device, link: () => links++);
      await selectHermes(tester, 'Voice output');
      expect(owner.current.values.voiceInput, AppVoiceProcessing.local);
      expect(owner.current.values.voiceOutput, AppVoiceProcessing.hermes);
      expect(find.text('Android voice'), findsNothing);
      expect(
        find.textContaining('belong to the selected server profile'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Open speech synthesis'));
      await tester.tap(find.text('Open speech synthesis'));
      expect(links, 1);
      await tester.pumpWidget(const SizedBox());
      await prefs.reload();
      final reopened = AppPreferences(prefs);
      addTearDown(reopened.dispose);
      await show(tester, reopened, device);
      expect(
        tester
            .widgetList<StudioSelect<AppVoiceProcessing>>(
              find.byType(StudioSelect<AppVoiceProcessing>),
            )
            .firstWhere((w) => w.label == 'Voice output')
            .value,
        AppVoiceProcessing.hermes,
      );
    },
  );
  testWidgets('failed preference save keeps confirmed value after reopening', (
    tester,
  ) async {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = _FailingStorage();
    final prefs = await SharedPreferences.getInstance();
    final owner = AppPreferences(prefs);
    addTearDown(owner.dispose);
    final device = VoiceDeviceFixture();
    addTearDown(device.stream.close);
    await show(tester, owner, device);
    await selectHermes(tester, 'Voice input');
    expect(
      find.text('Could not save this voice setting. Please retry.'),
      findsOneWidget,
    );
    expect(owner.current.values.voiceInput, AppVoiceProcessing.local);
    await tester.pumpWidget(const SizedBox());
    await prefs.reload();
    final reopened = AppPreferences(prefs);
    addTearDown(reopened.dispose);
    await show(tester, reopened, device);
    expect(
      tester
          .widgetList<StudioSelect<AppVoiceProcessing>>(
            find.byType(StudioSelect<AppVoiceProcessing>),
          )
          .firstWhere((w) => w.label == 'Voice input')
          .value,
      AppVoiceProcessing.local,
    );
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'voice settings fit 320dp at ${scale * 100}% text in $brightness',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(320, 800);
          addTearDown(tester.view.reset);
          final prefs = await SharedPreferences.getInstance();
          final owner = AppPreferences(prefs);
          addTearDown(owner.dispose);
          final device = VoiceDeviceFixture();
          device.capabilitiesValue = const AndroidVoiceCapabilities(
            recognitionAvailable: false,
            voices: [
              (
                id: 'long',
                label:
                    'English (United Kingdom) · a very long installed Android voice name',
              ),
            ],
          );
          addTearDown(device.stream.close);
          await show(
            tester,
            owner,
            device,
            brightness: brightness,
            scale: scale,
            link: () {},
          );
          await screenshot(
            tester,
            'settings-input-${brightness.name}-${(scale * 100).round()}',
          );
          final liveField = find.byWidgetPredicate(
            (w) => w is StudioSelect<String> && w.label == 'GPT-Live voice',
          );
          await Scrollable.ensureVisible(
            tester.element(liveField),
            alignment: 0.2,
          );
          await tester.tap(
            find.descendant(of: liveField, matching: find.byType(TextField)),
          );
          await tester.pumpAndSettle();
          expect(find.text('Breeze').hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          await screenshot(
            tester,
            'live-voice-picker-${brightness.name}-${(scale * 100).round()}',
          );
          await tester.tap(find.text('Breeze').hitTestable());
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.text('Refresh Android voices and languages'),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await screenshot(
            tester,
            'settings-output-${brightness.name}-${(scale * 100).round()}',
          );
          await selectHermes(tester, 'Voice output');
          await tester.ensureVisible(
            find.text('Refresh Android voices and languages'),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await screenshot(
            tester,
            'settings-hermes-${brightness.name}-${(scale * 100).round()}',
          );
        },
      );
    }
  }
}
