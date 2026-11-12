import 'package:wing/core/models/settings_edit.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/administration/admin_speech_synthesis_page.dart';
import 'package:wing/core/screens/administration/admin_provider_credentials.dart';
import 'package:wing/core/services/voice_sample.dart';
import 'package:wing/core/widgets/studio_select.dart';
import 'package:wing/core/screens/administration/admin_voice_routes.dart';
import 'package:wing/core/theme/profile_workspace_theme.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'support/profile_voice_fixture.dart';
import 'support/voice_fixture.dart';

void main() {
  const frame = Key('profile-voice-frame');
  const capture = bool.fromEnvironment('VOICE_REVIEW');
  setUpAll(() async {
    if (!capture) return;
    const path = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            Future.value(
              ByteData.sublistView(
                File('$path/${entry.value}').readAsBytesSync(),
              ),
            ),
          ))
          .load();
    }
  });
  Future<void> show(
    WidgetTester tester,
    ProfileVoiceFixture f,
    VoiceDeviceFixture device, {
    Brightness brightness = Brightness.light,
    WorkspaceAccent accent = WorkspaceAccent.teal,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(
          brightness,
          accent: brightness == Brightness.dark ? accent.dark : accent.light,
        ),
        home: RepaintBoundary(
          key: frame,
          child: MediaQuery(
            data: MediaQueryData(
              size: tester.view.physicalSize / tester.view.devicePixelRatio,
              textScaler: TextScaler.linear(scale),
            ),
            child: profileSpeechSynthesisPage(
              f.server.profile('personal'),
              device: device,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
    await tester.pumpAndSettle();
  }

  Future<void> chooseVoice(WidgetTester tester, String name) async {
    final selector = find.byWidgetPredicate(
      (widget) =>
          widget is InputDecorator && widget.decoration.labelText == 'Voice',
    );
    await reveal(tester, selector);
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text(name).last,
      180,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(name).last);
  }

  Future<void> captureFrame(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(frame),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build/vanilla-voice-review').createSync(recursive: true);
      await File(
        'build/vanilla-voice-review/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'selection autosaves before Play and Stop controls native playback',
    (tester) async {
      final f = ProfileVoiceFixture()..writeGate = Completer();
      final device = VoiceDeviceFixture()..playbackDelay = Completer();
      addTearDown(device.stream.close);
      await show(tester, f, device);
      expect(find.text('Save'), findsNothing);
      expect(find.text(voiceSampleText), findsNothing);
      expect(find.text('Saved'), findsNothing);
      await chooseVoice(tester, 'Jenny');
      await tester.pump();
      expect(find.text('Saving…'), findsOneWidget);
      expect(
        tester
            .widget<StudioSelect<String>>(find.byType(StudioSelect<String>))
            .onChanged,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Play'))
            .onPressed,
        isNull,
      );
      f.writeGate!.complete();
      await tester.pumpAndSettle();
      expect(
        setting(f.configs['personal']!, 'tts.edge.voice'),
        'en-US-JennyNeural',
      );
      await Scrollable.ensureVisible(
        tester.element(find.text('Play')),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();
      expect(device.calls, contains('play'));
      expect(device.calls, isNot(contains('speak')));
      expect(f.requests.singleWhere((r) => r.$2 == 'audio/speak').$4, {
        'text': voiceSampleText,
      });
      expect(find.text('Stop'), findsOneWidget);
      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      expect(device.playing, isNull);
      device.playbackDelay!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Play'), findsOneWidget);
    },
  );

  for (final cancellation in ['stop', 'select', 'background', 'leave']) {
    testWidgets('$cancellation discards late synthesis', (tester) async {
      final f = ProfileVoiceFixture()..audioGate = Completer();
      final device = VoiceDeviceFixture();
      addTearDown(device.stream.close);
      await show(tester, f, device);
      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();
      expect(find.text('Preparing audio…'), findsOneWidget);
      switch (cancellation) {
        case 'stop':
          await tester.tap(find.text('Stop'));
        case 'select':
          await chooseVoice(tester, 'Jenny');
        case 'background':
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        case 'leave':
          await tester.pumpWidget(const SizedBox());
      }
      await tester.pumpAndSettle();
      f.audioGate!.complete(f.audio);
      await tester.pumpAndSettle();
      expect(device.calls, isNot(contains('play')));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
  }

  testWidgets('failed autosave requires refresh and retains confirmed voice', (
    tester,
  ) async {
    final f = ProfileVoiceFixture()..reject = true;
    final device = VoiceDeviceFixture();
    addTearDown(device.stream.close);
    await show(tester, f, device);
    await chooseVoice(tester, 'Jenny');
    await tester.pumpAndSettle();
    expect(
      find.text('Save not confirmed. Refresh before trying again.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Play'))
          .onPressed,
      isNull,
    );
    expect(
      setting(f.configs['personal']!, 'tts.edge.voice'),
      'en-US-AriaNeural',
    );
    f.reject = false;
    await tester.tap(find.byTooltip('Refresh speech settings'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Play'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('custom IDs autosave and ElevenLabs voices come from account', (
    tester,
  ) async {
    final f = ProfileVoiceFixture();
    setSetting(f.configs['personal']!, 'tts.provider', 'elevenlabs');
    final device = VoiceDeviceFixture();
    addTearDown(device.stream.close);
    await show(tester, f, device);
    expect(find.text('Narrator'), findsOneWidget);
    await reveal(tester, find.text('Advanced'));
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    final field = find.widgetWithText(TextField, 'Voice ID');
    await reveal(tester, field);
    await tester.enterText(field, 'account-voice-123');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
      setting(f.configs['personal']!, 'tts.elevenlabs.voice_id'),
      'account-voice-123',
    );
    await chooseVoice(tester, 'Storyteller');
    await tester.pumpAndSettle();
    expect(
      setting(f.configs['personal']!, 'tts.elevenlabs.voice_id'),
      'custom-b',
    );
  });

  testWidgets('administration opens the combined editor without a voice page', (
    tester,
  ) async {
    final f = ProfileVoiceFixture();
    final device = VoiceDeviceFixture();
    addTearDown(device.stream.close);
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.light),
        home: profileVoicePage(f.server.profile('personal'), device: device),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Profile voice'), findsNothing);
    await tester.tap(find.text('Speech synthesis provider'));
    await tester.pumpAndSettle();
    expect(find.byType(AdminSpeechSynthesisPage), findsOneWidget);
    expect(find.text('Aria'), findsOneWidget);
    expect(find.text(voiceSampleText), findsNothing);
  });

  testWidgets('large account catalogue is searchable inside the picker', (
    tester,
  ) async {
    final f = ProfileVoiceFixture();
    setSetting(f.configs['personal']!, 'tts.provider', 'elevenlabs');
    f.catalogue = {
      'available': true,
      'voices': [
        for (var index = 0; index < 30; index++)
          {
            'voice_id': 'v$index',
            'name': 'Narrator $index',
            'label': 'Narrator $index',
          },
      ],
    };
    final device = VoiceDeviceFixture();
    addTearDown(device.stream.close);
    await show(tester, f, device);
    expect(find.text('Search voices'), findsNothing);
    await tester.tap(find.text('custom-a'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Search voices'),
      'Narrator 27',
    );
    await tester.pumpAndSettle();
    expect(find.text('Narrator 1'), findsNothing);
    await tester.tap(find.text('Narrator 27').last);
    await tester.pumpAndSettle();
    expect(setting(f.configs['personal']!, 'tts.elevenlabs.voice_id'), 'v27');
  });

  for (final brightness in Brightness.values) {
    testWidgets('normal phone layout $brightness', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final device = VoiceDeviceFixture();
      addTearDown(device.stream.close);
      await show(tester, ProfileVoiceFixture(), device, brightness: brightness);
      expect(tester.takeException(), isNull);
      await captureFrame(tester, '${brightness.name}-phone');
      await chooseVoice(tester, 'Jenny');
      await tester.pumpAndSettle();
      expect(find.text('Jenny'), findsOneWidget);
    });
  }

  testWidgets('provider changes reload voices and cancel pending speech', (
    tester,
  ) async {
    final f = ProfileVoiceFixture()..audioGate = Completer();
    final device = VoiceDeviceFixture();
    addTearDown(device.stream.close);
    await show(tester, f, device);
    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edge'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ElevenLabs').last);
    await tester.pumpAndSettle();
    expect(find.text('Narrator'), findsOneWidget);
    expect(find.text('Aria'), findsNothing);
    expect(setting(f.configs['personal']!, 'tts.provider'), 'elevenlabs');
    f.audioGate!.complete(f.audio);
    await tester.pumpAndSettle();
    expect(device.calls, isNot(contains('play')));
    await chooseVoice(tester, 'Storyteller');
    await tester.pumpAndSettle();
    expect(
      setting(f.configs['personal']!, 'tts.elevenlabs.voice_id'),
      'custom-b',
    );
  });

  for (final name in ['Nous Subscription', 'OpenAI TTS']) {
    testWidgets('$name selection keeps its own provider identity', (
      tester,
    ) async {
      final f = ProfileVoiceFixture();
      final device = VoiceDeviceFixture();
      addTearDown(device.stream.close);
      await show(tester, f, device);
      await tester.tap(find.text('Edge'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(name).last);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Provider selection could not be confirmed'),
        findsNothing,
      );
      expect(
        tester
            .widget<StudioSelect<String>>(find.byType(StudioSelect<String>))
            .value,
        name,
      );
      if (name == 'Nous Subscription') {
        expect(
          find.text('Sign in to this provider on Hermes, then refresh.'),
          findsOneWidget,
        );
      } else {
        expect(find.text('alloy'), findsOneWidget);
      }
      await tester.tap(find.byTooltip('Refresh speech settings'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<StudioSelect<String>>(find.byType(StudioSelect<String>))
            .value,
        name,
      );
    });
  }

  testWidgets(
    'ready Nous keeps its identity and OpenAI voice after reopening',
    (tester) async {
      final f = ProfileVoiceFixture()..nousReady = true;
      setSetting(f.configs['personal']!, 'tts.provider', 'nous');
      final device = VoiceDeviceFixture();
      addTearDown(device.stream.close);
      await show(tester, f, device);
      expect(
        tester
            .widget<StudioSelect<String>>(find.byType(StudioSelect<String>))
            .value,
        'Nous Subscription',
      );
      expect(find.text('alloy'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Play'))
            .onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox());
      await show(tester, f, device);
      expect(
        tester
            .widget<StudioSelect<String>>(find.byType(StudioSelect<String>))
            .value,
        'Nous Subscription',
      );
      expect(find.text('alloy'), findsOneWidget);
    },
  );

  testWidgets('missing credentials show setup before voice controls', (
    tester,
  ) async {
    final f = ProfileVoiceFixture()..elevenLabsReady = false;
    setSetting(f.configs['personal']!, 'tts.provider', 'elevenlabs');
    final device = VoiceDeviceFixture();
    addTearDown(device.stream.close);
    await show(tester, f, device);
    expect(find.text('API key'), findsOneWidget);
    expect(find.text('Play'), findsNothing);
    f.elevenLabsReady = true;
    await tester.tap(find.byTooltip('Refresh speech settings'));
    await tester.pumpAndSettle();
    expect(find.text('Play'), findsOneWidget);
  });

  testWidgets('speech credential entry prepares current profile metadata', (
    tester,
  ) async {
    final f = ProfileVoiceFixture()..elevenLabsReady = false;
    setSetting(f.configs['personal']!, 'tts.provider', 'elevenlabs');
    final device = VoiceDeviceFixture();
    addTearDown(device.stream.close);
    await show(tester, f, device);
    f.override = (method, path, query, body) async {
      expect((method, path), ('GET', 'env'));
      expect(query, {'profile': 'personal'});
      return {
        'ELEVENLABS_API_KEY': {
          'is_set': true,
          'channel_managed': false,
          'category': 'api_keys',
          'provider_label': 'ElevenLabs',
        },
      };
    };
    await tester.tap(find.text('API key'));
    await tester.pumpAndSettle();
    expect(find.byType(AdminSecretPage), findsOneWidget);
    expect(find.text('Remove stored credential'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).obscureText,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('unconfirmed provider save disables playback until refresh', (
    tester,
  ) async {
    final f = ProfileVoiceFixture()..ignoreSave = true;
    final device = VoiceDeviceFixture();
    addTearDown(device.stream.close);
    await show(tester, f, device);
    await tester.tap(find.text('Edge'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ElevenLabs').last);
    await tester.pumpAndSettle();
    expect(
      find.textContaining(
        'Provider selection saved, but current settings differ',
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Play'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('Refresh speech settings'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Play'))
          .onPressed,
      isNotNull,
    );
  });

  for (final brightness in Brightness.values) {
    for (final accent in WorkspaceAccent.values) {
      testWidgets('320dp 200% text $brightness $accent', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 800);
        addTearDown(tester.view.reset);
        final f = ProfileVoiceFixture();
        setSetting(
          f.configs['personal']!,
          'tts.edge.voice',
          'en-US-A-very-long-custom-voice-ID',
        );
        final device = VoiceDeviceFixture();
        addTearDown(device.stream.close);
        await show(
          tester,
          f,
          device,
          brightness: brightness,
          accent: accent,
          scale: 2,
        );
        expect(tester.takeException(), isNull);
        await captureFrame(tester, '${brightness.name}-${accent.name}-top');
        await tester.scrollUntilVisible(
          find.text('Advanced'),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await Scrollable.ensureVisible(
          tester.element(find.text('Advanced')),
          alignment: 0.5,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Advanced'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.widgetWithText(TextField, 'Voice ID'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
