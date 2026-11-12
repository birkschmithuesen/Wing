import 'package:wing/core/services/owned_remote_files.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/remote_files_client.dart';

class _StreamingClient extends http.BaseClient {
  _StreamingClient({required this.declaredLength});

  final bool declaredLength;
  static const byteCount = 33 * 1024 * 1024;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        Stream<List<int>>.fromIterable(
          List.generate(33, (index) {
            final chunk = Uint8List(1024 * 1024);
            chunk.first = index;
            chunk.last = 255 - index;
            return chunk;
          }),
        ),
        200,
        contentLength: declaredLength ? byteCount : null,
        headers: {'content-disposition': 'attachment; filename=delivery.zip'},
      );
}

void main() {
  test('downloaded file facts copy and reject byte mutation', () {
    final original = <int>[1, 2, 3];
    final file = RemoteFileDownload(filename: 'report.txt', bytes: original);
    original[0] = 9;
    expect(file.bytes, [1, 2, 3]);
    expect(() => file.bytes[0] = 9, throwsUnsupportedError);
    expect(file.bytes, [1, 2, 3]);
  });

  DashboardClient dashboardWith(
    Future<http.Response> Function(http.Request request) handler,
  ) {
    final dashboard = DashboardClient(
      host: 'hermes.local',
      port: 9119,
      proxied: true,
      httpClient: MockClient(handler),
    );
    addTearDown(dashboard.close);
    return dashboard;
  }

  test('owned file access keeps the original profile and saved chat', () async {
    final requests = <http.Request>[];
    final dashboard = dashboardWith((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/read-text')) {
        return http.Response(
          jsonEncode({
            'path': request.url.queryParameters['path'],
            'text': 'contents',
          }),
          200,
        );
      }
      return http.Response.bytes(
        [1, 2, 3],
        200,
        headers: {'content-disposition': 'attachment; filename=report.txt'},
      );
    });
    final client = RemoteFilesClient(dashboard: dashboard);
    final owned = OwnedRemoteFiles(
      source: client,
      profileName: 'original-profile',
      storedSessionId: 'original-chat',
      release: client.close,
    );

    await owned.readText('../exports/report.txt');
    await owned.download('../exports/report.txt');

    expect(requests.map((request) => request.url.path), [
      '/api/fs/read-text',
      '/api/fs/download',
    ]);
    expect(requests[0].url.queryParameters, {
      'path': '../exports/report.txt',
      'profile': 'original-profile',
      'session_id': 'original-chat',
    });
    expect(requests[1].url.queryParameters, {
      'path': '../exports/report.txt',
      'profile': 'original-profile',
      'session_id': 'original-chat',
    });
  });

  test('relative preview preserves the server session refusal', () async {
    var requests = 0;
    final client = RemoteFilesClient(
      dashboard: dashboardWith((request) async {
        requests++;
        expect(request.url.path, '/api/fs/read-text');
        expect(request.url.queryParameters, {
          'path': 'report.md',
          'profile': 'writer',
          'session_id': 'chat-7',
        });
        return http.Response(jsonEncode({'detail': 'Session not found'}), 404);
      }),
    );
    await expectLater(
      client.readText(
        'report.md',
        profileName: 'writer',
        storedSessionId: 'chat-7',
      ),
      throwsA(isA<DashboardHttpException>()),
    );
    expect(requests, 1);
  });

  test('reads a text preview with language and truncation metadata', () async {
    final dashboard = dashboardWith((request) async {
      expect(request.url.path, '/api/fs/read-text');
      expect(request.url.queryParameters['path'], '/srv/project/main.dart');
      expect(request.url.queryParameters['profile'], 'writer');
      expect(request.url.queryParameters['session_id'], 'chat-7');
      return http.Response(
        jsonEncode({
          'path': '/srv/project/main.dart',
          'text': 'void main() {}',
          'language': 'dart',
          'mimeType': 'text/x-dart',
          'byteSize': 14,
          'binary': false,
          'truncated': true,
        }),
        200,
      );
    });
    final client = RemoteFilesClient(dashboard: dashboard);

    final preview = await client.readText(
      '/srv/project/main.dart',
      profileName: 'writer',
      storedSessionId: 'chat-7',
    );

    expect(preview.text, 'void main() {}');
    expect(preview.language, 'dart');
    expect(preview.truncated, isTrue);
  });

  test('downloads bytes with the server filename', () async {
    final dashboard = dashboardWith((request) async {
      expect(request.url.path, '/api/fs/download');
      expect(request.url.queryParameters['path'], '/srv/project/report.pdf');
      expect(request.url.queryParameters['profile'], 'writer');
      expect(request.url.queryParameters['session_id'], 'chat-7');
      return http.Response.bytes(
        [1, 2, 3],
        200,
        headers: {'content-disposition': 'attachment; filename="report.pdf"'},
      );
    });
    final client = RemoteFilesClient(dashboard: dashboard);

    final download = await client.download(
      '/srv/project/report.pdf',
      profileName: 'writer',
      storedSessionId: 'chat-7',
    );

    expect(download.filename, 'report.pdf');
    expect(download.bytes, [1, 2, 3]);
  });

  for (final declaredLength in [true, false]) {
    test(
      'downloads a 33 MiB file with declared length $declaredLength',
      () async {
        final dashboard = DashboardClient(
          host: 'hermes.local',
          port: 9119,
          proxied: true,
          httpClient: _StreamingClient(declaredLength: declaredLength),
        );
        addTearDown(dashboard.close);
        final client = RemoteFilesClient(dashboard: dashboard);

        final download = await client.download(
          '/srv/project/delivery.zip',
          profileName: 'writer',
          storedSessionId: 'chat-7',
        );
        expect(download.filename, 'delivery.zip');
        expect(download.bytes.length, _StreamingClient.byteCount);
        for (var index = 0; index < 33; index++) {
          expect(download.bytes[index * 1024 * 1024], index);
          expect(download.bytes[(index + 1) * 1024 * 1024 - 1], 255 - index);
        }
      },
    );
  }

  test('download reduces encoded server filenames to a basename', () async {
    final dashboard = dashboardWith(
      (_) async => http.Response.bytes(
        [1],
        200,
        headers: {
          'content-disposition':
              "attachment; filename*=UTF-8''..%2Fprivate%2Freport%20one.pdf",
        },
      ),
    );
    final client = RemoteFilesClient(dashboard: dashboard);

    final download = await client.download(
      '/srv/private/internal-name',
      profileName: 'writer',
      storedSessionId: 'chat-7',
    );

    expect(download.filename, 'report one.pdf');
  });

  for (final operation in ['preview', 'download']) {
    for (final missing in ['profile', 'session']) {
      test('$operation refuses missing $missing before network I/O', () async {
        final requests = <http.Request>[];
        final dashboard = dashboardWith((request) async {
          requests.add(request);
          return http.Response('{}', 200);
        });
        final client = RemoteFilesClient(dashboard: dashboard);
        final profile = missing == 'profile' ? '' : 'writer';
        final session = missing == 'session' ? '' : 'chat-7';
        final result = operation == 'preview'
            ? client.readText(
                '/srv/project/report.md',
                profileName: profile,
                storedSessionId: session,
              )
            : client.download(
                '/srv/project/report.md',
                profileName: profile,
                storedSessionId: session,
              );
        await expectLater(result, throwsArgumentError);
        expect(requests, isEmpty);
      });
    }
  }
}
