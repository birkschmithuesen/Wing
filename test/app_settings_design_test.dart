import 'package:wing/core/services/voice_preferences_session.dart';
import 'package:wing/core/services/android_voice.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/config/support_wing.dart';
import 'package:wing/core/screens/app_settings_content.dart';
import 'package:wing/core/theme/profile_workspace_theme.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/theme/wing_icons.dart';
import 'package:wing/core/widgets/support_wing_section.dart';

const _capture = bool.fromEnvironment('CAPTURE_SETTINGS');
const _frame = Key('settings-frame');

Future<void> _captureFrame(WidgetTester tester, String name) async {
  if (!_capture) return;
  final context = tester.element(find.byKey(_frame));
  final images = tester.widgetList<Image>(find.byType(Image)).toList();
  await tester.runAsync(() async {
    await Future.wait(
      images.map((image) => precacheImage(image.image, context)),
    );
  });
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_frame),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory('build/settings-review').createSync(recursive: true);
    await File(
      'build/settings-review/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _show(
  WidgetTester tester,
  AppPreferences appPreferences, {
  Brightness brightness = Brightness.light,
  double scale = 1,
}) async {
  await tester.pumpWidget(
    RepaintBoundary(
      key: _frame,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: wingTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          appBar: AppBar(title: const Text('App settings')),
          body: AppSettingsContent(
            pluginServer: null,
            preferences: appPreferences,
            createVoiceSession: () => VoicePreferencesSession(
              preferences: appPreferences,
              device: AndroidVoice.instance,
              hermesProfileLabel: null,
              openHermesSettings: null,
            ),
            onChanged: () {},
            enableNotifications: () async {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    if (!_capture) return;
    const directory = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      'Roboto': ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf'],
      'MaterialIcons': ['MaterialIcons-Regular.otf'],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final name in entry.value) {
        loader.addFont(
          Future.value(
            ByteData.sublistView(File('$directory/$name').readAsBytesSync()),
          ),
        );
      }
      await loader.load();
    }
    await (FontLoader('WingProjectIcons')..addFont(
          File(
            'assets/fonts/codicons.ttf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
    await (FontLoader('WingIcons')..addFont(
          File(
            'assets/fonts/wing-icons.ttf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Wing',
      packageName: 'com.tarkilhk.wing',
      version: '1.0.0',
      buildNumber: '2239',
      buildSignature: '',
    );
  });

  testWidgets('About permanently exposes both contribution destinations', (
    tester,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    final appPreferences = AppPreferences(preferences);
    addTearDown(appPreferences.dispose);
    await _show(tester, appPreferences);
    await tester.ensureVisible(find.text('Buy me a coffee'));
    await tester.pumpAndSettle();
    expect(find.text('Support Wing'), findsOneWidget);
    expect(find.text('Buy me a coffee'), findsOneWidget);
    expect(find.text('Sponsor on GitHub'), findsOneWidget);
    expect(
      tester
          .widget<SupportWingSection>(find.byType(SupportWingSection))
          .koFiUri,
      wingKoFiUri,
    );
    expect(
      tester
          .widget<SupportWingSection>(find.byType(SupportWingSection))
          .githubUri,
      wingGitHubSponsorsUri,
    );
  });

  testWidgets(
    'saved theme and accent update the preview and survive reopening',
    (tester) async {
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final confirmedAppearance =
          <(AppThemePreference?, AppAccentPreference?)>[];
      var previous = (
        appPreferences.current.values.theme,
        appPreferences.current.values.accent,
      );
      void observeAppearance() {
        final next = (
          appPreferences.current.values.theme,
          appPreferences.current.values.accent,
        );
        if (next != previous) {
          confirmedAppearance.add(next);
          previous = next;
        }
      }

      appPreferences.state.addListener(observeAppearance);
      addTearDown(() => appPreferences.state.removeListener(observeAppearance));
      await _show(tester, appPreferences);
      await tester.ensureVisible(find.byKey(const ValueKey('theme-dark')));
      await tester.tap(find.byKey(const ValueKey('theme-dark')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('accent-iris')));
      await tester.tap(find.byKey(const ValueKey('accent-iris')));
      await tester.pumpAndSettle();
      final previewContext = tester.element(
        find.byKey(const ValueKey('appearance-preview')),
      );
      expect(Theme.of(previewContext).brightness, Brightness.dark);
      expect(
        Theme.of(previewContext).colorScheme.primary,
        WorkspaceAccent.iris.dark,
      );
      expect(preferences.getString('theme_mode'), 'dark');
      expect(
        preferences.getString(AppPreferenceField.accent.storageKey),
        'iris',
      );
      expect(confirmedAppearance, [
        (AppThemePreference.dark, AppAccentPreference.teal),
        (AppThemePreference.dark, AppAccentPreference.iris),
      ]);
      await tester.pumpWidget(const SizedBox());
      await preferences.reload();
      final reopened = AppPreferences(preferences);
      addTearDown(reopened.dispose);
      await _show(tester, reopened);
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const ValueKey('theme-dark')))
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const ValueKey('accent-iris')))
            .selected,
        isTrue,
      );
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('settings and text picker fit $brightness at ${scale}x', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        final preferences = await SharedPreferences.getInstance();
        final appPreferences = AppPreferences(preferences);
        addTearDown(appPreferences.dispose);
        await _show(
          tester,
          appPreferences,
          brightness: brightness,
          scale: scale,
        );
        await _captureFrame(tester, '${brightness.name}-$scale-appearance');
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Text size'));
        await tester.tap(find.text('Text size'));
        await tester.pumpAndSettle();
        await _captureFrame(tester, '${brightness.name}-$scale-text-size');
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Extra large'));
        await tester.tap(find.text('Extra large'));
        await tester.pumpAndSettle();
        expect(
          preferences.getString('app_text_size_preference'),
          'extra_large',
        );
        final queue = find.widgetWithText(ChoiceChip, 'Queue');
        await tester.ensureVisible(queue);
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: queue, matching: find.byIcon(WingIcons.queue)),
          findsOneWidget,
        );
        await _captureFrame(
          tester,
          '${brightness.name}-$scale-composer-actions',
        );
        await tester.tap(queue);
        await tester.pumpAndSettle();
        expect(preferences.getString('composer_running_action'), 'queue');
        final linkChoices = find.byKey(const ValueKey('link-destination'));
        final label = find.text('Open links in');
        await tester.ensureVisible(linkChoices);
        await tester.pumpAndSettle();
        void expectOneLine(String value) {
          final displayed = find.descendant(
            of: linkChoices,
            matching: find.text(value),
          );
          expect(displayed.hitTestable(), findsOneWidget);
          expect(
            tester.getCenter(displayed).dy,
            closeTo(tester.getCenter(label).dy, 1),
          );
          for (final text in [label, displayed]) {
            expect(tester.widget<Text>(text).maxLines, 1);
            final paragraph = find.descendant(
              of: text,
              matching: find.byType(RichText),
            );
            expect(
              tester.renderObject<RenderParagraph>(paragraph).didExceedMaxLines,
              isFalse,
            );
          }
        }

        expectOneLine('Wing');
        await _captureFrame(
          tester,
          '${brightness.name}-$scale-link-destination',
        );
        await tester.tap(linkChoices);
        await tester.pumpAndSettle();
        final externalBrowser = find.text('Open in external browser');
        expect(externalBrowser.hitTestable(), findsOneWidget);
        await _captureFrame(tester, '${brightness.name}-$scale-link-menu');
        await tester.tap(externalBrowser);
        await tester.pumpAndSettle();
        expectOneLine('Browser');
        await tester.ensureVisible(
          find.byKey(const ValueKey('privacy-policy')),
        );
        await tester.pumpAndSettle();
        await _captureFrame(tester, '${brightness.name}-$scale-about');
        await tester.ensureVisible(find.text('Buy me a coffee'));
        await tester.pumpAndSettle();
        await _captureFrame(tester, '${brightness.name}-$scale-support');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
