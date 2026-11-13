import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/services/android_voice.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/services/voice_preferences_session.dart';
import 'package:wing/core/widgets/studio_select.dart';
import 'package:wing/core/widgets/voice_preferences_card.dart';

import 'support/voice_fixture.dart';

void main() {
  testWidgets(
    'closing voice settings during preview stop never submits a pending choice',
    (tester) async {
      SharedPreferences.resetStatic();
      final storage = _VoicePreferenceStorage();
      SharedPreferencesStorePlatform.instance = storage;
      final preferences = await SharedPreferences.getInstance();
      final owner = AppPreferences(preferences);
      addTearDown(owner.dispose);
      final device = _HeldPreviewStop();
      addTearDown(() async {
        if (!device.stopRelease.isCompleted) {
          device.stopRelease.complete();
        }
        if (!device.playbackDelay!.isCompleted) {
          device.playbackDelay!.complete();
        }
        await device.stream.close();
        SharedPreferences.setMockInitialValues({});
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: VoicePreferencesCard(
                createSession: () => VoicePreferencesSession(
                  preferences: owner,
                  device: device,
                  hermesProfileLabel: null,
                  openHermesSettings: null,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Preview Android voice'));
      await tester.tap(find.text('Preview Android voice'));
      await tester.pump();
      expect(device.calls, contains('speak'));
      expect(device.playing, isNotNull);
      expect(storage.outputWrites, isEmpty);

      final output = find.byWidgetPredicate(
        (widget) =>
            widget is StudioSelect<AppVoiceProcessing> &&
            widget.label == 'Voice output',
      );
      await tester.ensureVisible(output);
      await tester.tap(
        find.descendant(of: output, matching: find.byType(TextField)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Hermes · server profile').hitTestable().last);
      await tester.pump();
      expect(device.stopStarted.isCompleted, isTrue);
      expect(storage.outputWrites, isEmpty);

      await tester.pumpWidget(const SizedBox());
      device.stopRelease.complete();
      device.playbackDelay!.complete();
      await tester.pumpAndSettle();
      expect(
        storage.outputWrites,
        isEmpty,
        reason: 'route closure precedes physical preference dispatch',
      );
      expect((await storage.getAll())['flutter.voice.output'], 'local');
      await preferences.reload();
      expect(preferences.getString('voice.output'), 'local');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an older capability read cannot replace the resumed observation',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final owner = AppPreferences(preferences);
      addTearDown(owner.dispose);
      final device = _HeldCapabilityRefresh();
      addTearDown(() async {
        if (!device.first.isCompleted) device.first.complete(device.old);
        await device.stream.close();
        SharedPreferences.setMockInitialValues({});
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: VoicePreferencesCard(
                createSession: () => VoicePreferencesSession(
                  preferences: owner,
                  device: device,
                  hermesProfileLabel: null,
                  openHermesSettings: null,
                ),
              ),
            ),
          ),
        ),
      );
      expect(device.capabilityReads, 1);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(device.capabilityReads, 2);
      List<String> displayedVoices() => tester
          .widgetList<StudioSelect<String>>(find.byType(StudioSelect<String>))
          .firstWhere((field) => field.label == 'Android voice')
          .options
          .map((choice) => choice.value)
          .toList();
      expect(displayedVoices(), ['', 'fresh']);
      expect(preferences.getKeys(), isEmpty);
      expect(tester.takeException(), isNull);

      device.first.complete(device.old);
      await tester.pumpAndSettle();
      expect(preferences.getKeys(), isEmpty);
      expect(
        displayedVoices(),
        ['', 'fresh'],
        reason:
            'the latest completed capability observation must remain visible',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class _HeldPreviewStop extends VoiceDeviceFixture {
  _HeldPreviewStop() {
    playbackDelay = Completer<void>();
  }
  final stopStarted = Completer<void>();
  final stopRelease = Completer<void>();

  @override
  Future<void> stopPlayback(String id) async {
    stopStarted.complete();
    await stopRelease.future;
    await super.stopPlayback(id);
  }
}

class _VoicePreferenceStorage extends InMemorySharedPreferencesStore {
  _VoicePreferenceStorage() : super.withData({'flutter.voice.output': 'local'});
  final outputWrites = <Object>[];

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (key == 'flutter.voice.output') outputWrites.add(value);
    return super.setValue(valueType, key, value);
  }
}

class _HeldCapabilityRefresh extends VoiceDeviceFixture {
  final first = Completer<AndroidVoiceCapabilities>();
  int capabilityReads = 0;
  final old = const AndroidVoiceCapabilities(
    recognitionAvailable: true,
    installedLanguages: ['en-US'],
    voices: [(id: 'old', label: 'Older voice')],
  );
  final fresh = const AndroidVoiceCapabilities(
    recognitionAvailable: true,
    installedLanguages: ['fr-FR'],
    voices: [(id: 'fresh', label: 'Latest voice')],
  );

  @override
  Future<AndroidVoiceCapabilities> capabilities() {
    capabilityReads++;
    return switch (capabilityReads) {
      1 => first.future,
      2 => Future.value(fresh),
      _ => throw StateError('Unexpected capability read'),
    };
  }
}
