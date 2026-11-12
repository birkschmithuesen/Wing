import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/hermes_voice.dart';

void main() {
  for (final synthesis in [false, true]) {
    test(
      'authenticated ${synthesis ? 'synthesis' : 'transcription'} retains profile and body across renewal',
      () async {
        var logins = 0;
        final bodies = <Map<String, dynamic>>[];
        final dashboard = DashboardClient(
          host: 'hermes.test',
          port: 9119,
          username: 'owner',
          password: 'fixture',
          httpClient: MockClient((request) async {
            if (request.url.path == '/auth/password-login') {
              logins++;
              return http.Response(
                '{"ok":true}',
                200,
                headers: {
                  'set-cookie': 'hermes_session_at=fixture$logins; Path=/',
                },
              );
            }
            expect(request.method, 'POST');
            expect(request.headers['cookie'], contains('hermes_session_at='));
            expect(request.url.queryParameters, {'profile': 'work'});
            expect(
              request.url.path,
              synthesis ? '/api/audio/speak' : '/api/audio/transcribe',
            );
            bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
            if (bodies.length == 1) return http.Response('', 401);
            return http.Response(
              synthesis
                  ? '{"ok":true,"data_url":"data:audio/wav;base64,AQID"}'
                  : '{"ok":true,"transcript":" Hello ","provider":"fixture"}',
              200,
            );
          }),
        );
        final client = HermesVoice(
          profile: 'work',
          request: (path, body) => dashboard.apiPost(path, body: body),
          closeClient: dashboard.close,
        );
        addTearDown(client.close);
        if (synthesis) {
          expect(await client.synthesize('Reply'), [1, 2, 3]);
        } else {
          expect(
            await client.transcribe(Uint8List.fromList([1, 2, 3])),
            'Hello',
          );
        }
        expect(logins, 2);
        final expected = synthesis
            ? {'text': 'Reply'}
            : {
                'data_url': 'data:audio/mp4;base64,AQID',
                'mime_type': 'audio/mp4',
              };
        expect(bodies, [expected, expected]);
      },
    );
  }

  test('empty audio is rejected before a transcription request', () async {
    var calls = 0;
    final client = HermesVoice(
      profile: 'personal',
      closeClient: () {},
      request: (_, _) async {
        calls++;
        return {};
      },
    );
    addTearDown(client.close);
    await expectLater(client.transcribe(Uint8List(0)), throwsStateError);
    expect(calls, 0);
  });

  test('failed provider envelope cannot invent a transcript', () async {
    final client = HermesVoice(
      profile: 'personal',
      closeClient: () {},
      request: (_, _) async => {'ok': false, 'transcript': 'bad'},
    );
    addTearDown(client.close);
    await expectLater(
      client.transcribe(Uint8List.fromList([1])),
      throwsFormatException,
    );
  });

  for (final entry in <String, String>{
    'foreign URL': 'https://foreign.example/audio.mp3',
    'empty audio': 'data:audio/mp3;base64,',
  }.entries) {
    test('${entry.key} synthesis response is rejected', () async {
      final client = HermesVoice(
        profile: 'personal',
        closeClient: () {},
        request: (_, _) async => {'ok': true, 'data_url': entry.value},
      );
      addTearDown(client.close);
      await expectLater(client.synthesize('hello'), throwsFormatException);
    });
  }
}
