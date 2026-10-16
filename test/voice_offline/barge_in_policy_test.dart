import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/vad_endpoint.dart';
import 'package:wing/core/services/voice_preferences.dart';
import 'package:wing/voice_offline/barge_in_policy.dart';

void main() {
  group('listenConfig', () {
    test('keeps the pause, uses the listen minimum and never times out early', () {
      const settings = VoicePreferences(
        vad: VadEndpointConfig(
          pause: Duration(milliseconds: 1400),
          maxDuration: Duration(seconds: 900),
        ),
        listenMinSpeech: Duration(milliseconds: 600),
      );
      final config = listenConfig(settings);
      expect(config.pause, const Duration(milliseconds: 1400));
      expect(config.minSpeech, const Duration(milliseconds: 600));
      expect(config.maxDuration, const Duration(seconds: 900));
      expect(config.noSpeechTimeout, const Duration(seconds: 900));
    });

    test('a cough of 10 windows does not start speech at the 400 ms default', () {
      final endpointer = VadEndpointer(listenConfig(const VoicePreferences()));
      endpointer.feedAll([...List.filled(10, 0.9), ...List.filled(5, 0.1)]);
      expect(endpointer.speechStarted, isFalse);
      endpointer.feedAll(List.filled(13, 0.9));
      expect(endpointer.speechStarted, isTrue);
    });
  });

  group('PlaybackGate', () {
    test('fires once at the start of a long enough run', () {
      final gate = PlaybackGate(threshold: 0.7, windows: 16);
      int? fired;
      for (var i = 0; i < 40; i++) {
        // Not `fired ??= gate.feed(...)`: that short-circuits after the
        // first hit and would stop feeding the gate, leaving longestRun
        // short of the full run.
        final result = gate.feed(i, i < 4 ? 0.1 : 0.9);
        fired ??= result;
      }
      expect(fired, 4);
      expect(gate.firedAt, 4);
      expect(gate.longestRun, 36);
    });

    test('a cough (8 windows at 0.8) and echo bursts never fire', () {
      final gate = PlaybackGate(threshold: 0.7, windows: 16);
      final probabilities = [
        ...List.filled(8, 0.8),
        ...List.filled(20, 0.1),
        for (var i = 0; i < 60; i++) i % 7 < 6 ? 0.75 : 0.3,
      ];
      for (var i = 0; i < probabilities.length; i++) {
        expect(gate.feed(i, probabilities[i]), isNull);
      }
      expect(gate.firedAt, isNull);
      expect(gate.longestRun, 8);
    });

    test('a gap in window indices breaks the run', () {
      final gate = PlaybackGate(threshold: 0.7, windows: 3);
      expect(gate.feed(0, 0.9), isNull);
      expect(gate.feed(1, 0.9), isNull);
      expect(gate.feed(5, 0.9), isNull);
      expect(gate.feed(6, 0.9), isNull);
      expect(gate.feed(7, 0.9), 5);
    });
  });

  group('EchoStats', () {
    test('nearest-rank percentiles, maximum and runs', () {
      final stats = EchoStats();
      for (var i = 1; i <= 100; i++) {
        stats.add(i / 100);
      }
      expect(stats.windows, 100);
      expect(stats.max, 1.0);
      expect(stats.percentile(0.5), 0.5);
      expect(stats.percentile(0.99), 0.99);
      expect(stats.run50, 51);
      expect(stats.run70, 31);
      expect(
        stats.logLine(source: 'VOICE_COMMUNICATION', wouldTrigger: false),
        'probe windows=100 max=1.000 p50=0.500 p95=0.950 p99=0.990 '
        'run50=51 run70=31 wouldTrigger=0 source=VOICE_COMMUNICATION',
      );
    });

    test('empty stats log zeros', () {
      expect(EchoStats().percentile(0.99), 0);
      expect(EchoStats().max, 0);
    });
  });

  group('transcripts', () {
    for (final (text, sendable) in [
      ('', false),
      ('   ', false),
      ('.', false),
      ('Äh.', false),
      ('ähm, hm', false),
      ('Ja', true),
      ('nein', true),
      ('Äh, nimm lieber das Datum', true),
      ('Stopp', true),
    ]) {
      test('"$text" sendable: $sendable', () {
        expect(isSendableTranscript(text), sendable);
      });
    }
  });

  group('decideDelivery', () {
    test('status table', () {
      expect(decideDelivery(ListenChatState.steerable, 'Testsatz'), ListenDelivery.steer);
      expect(decideDelivery(ListenChatState.busy, 'Testsatz'), ListenDelivery.queue);
      expect(decideDelivery(ListenChatState.idle, 'Testsatz'), ListenDelivery.send);
      expect(
        decideDelivery(ListenChatState.steerable, 'Testsatz', steerRejected: true),
        ListenDelivery.queue,
      );
      expect(
        decideDelivery(ListenChatState.idle, 'Testsatz', steerRejected: true),
        ListenDelivery.send,
      );
    });

    test('unsendable text is dropped in every state', () {
      for (final state in ListenChatState.values) {
        expect(decideDelivery(state, 'hm'), ListenDelivery.drop);
      }
    });
  });

  test('gate constants stay inside the spec bounds', () {
    expect(bargeGateThreshold, inInclusiveRange(0.7, 0.9));
    expect(bargeGateWindows, inInclusiveRange(16, 31));
  });

  test('the probe text is synthetic German without digits', () {
    expect(echoProbeText, contains('Messtext'));
    expect(RegExp(r'\d').hasMatch(echoProbeText), isFalse);
  });

  test('the interrupted-reply hint follows the words after a blank line', () {
    expect(
      withInterruptedReplyHint('Testsatz zwei, stopp '),
      'Testsatz zwei, stopp\n\n'
      '[Hinweis von Wing: Die vorige Antwort wurde beim Vorlesen abgebrochen '
      'und nicht zu Ende gehört.]',
    );
  });
}
