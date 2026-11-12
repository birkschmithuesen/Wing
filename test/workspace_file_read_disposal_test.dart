import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/owned_remote_files.dart';
import 'package:wing/core/services/transcript_resource_session.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/remote_files_client.dart';

import 'answer_versions_test.dart' show AnswerHost;
import 'helpers/pump_markdown_widget.dart';

/// Returns headers immediately, then stalls the response body indefinitely.
/// Closing this fake client deliberately does not cancel its stream: the test
/// checks that the production read transport actually cancels its subscription.
class _StalledBodyClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  late final body = StreamController<List<int>>(
    onCancel: () => bodyCancelled = true,
  );
  bool bodyCancelled = false;
  int closeCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(body.stream, 200, contentLength: 1024);
  }

  @override
  void close() => closeCount++;
}

class _FileReadController extends ProfileWorkspaceController {
  _FileReadController(
    SharedPreferences preferences,
    this.host,
    this.transport, {
    required super.appPreferences,
  }) : super(
         access: ConnectionAccess(
           connection: SavedConnection(
             id: 'file-reader',
             label: 'File reader',
             host: 'localhost',
             port: 1,
             apiKey: '',
           ),
           dashboardOAuth: null,
         ),
         connectionIdentity: 'file-reader-owner',
         preferences: preferences,
         gatewayFactory: host.gateway,
       );

  final _StalledBodyClient transport;
  final AnswerHost host;

  @override
  TranscriptResourceSession traceResources(ProfileSessionKey key) {
    final files = RemoteFilesClient(
      dashboard: DashboardClient(
        host: 'localhost',
        proxied: true,
        httpClient: transport,
        readTimeout: const Duration(minutes: 1),
      ),
    );
    final gateway = host.gateway(key.workspace);
    return TranscriptResourceSession(
      files: OwnedRemoteFiles(
        source: files,
        profileName: key.workspace.profileName,
        storedSessionId: key.sessionId,
        release: files.close,
      ),
      loadHistory: (offset) => gateway.history(key.sessionId, offset: offset),
      createSkillReader: gateway.skillReader,
    );
  }
}

void main() {
  for (final attachmentImage in [false, true]) {
    testWidgets(
      'workspace removal aborts a stalled ${attachmentImage ? 'attachment image' : 'inline download'}',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final appPreferences = AppPreferences(preferences);
        addTearDown(appPreferences.dispose);
        final transport = _StalledBodyClient();
        final host = AnswerHost();
        final path = attachmentImage
            ? '/output/picture.png'
            : '/output/report.pdf';
        host.histories['a/original'] = [
          {
            'role': attachmentImage ? 'user' : 'assistant',
            'text': attachmentImage
                ? '@image:$path'
                : '[Download report]($path)',
            'row_id': 1,
          },
        ];
        final controller = _FileReadController(
          preferences,
          host,
          transport,
          appPreferences: appPreferences,
        );
        addTearDown(() async {
          controller.dispose();
          await transport.body.close();
        });
        await controller.initialize();
        await controller.openSession(
          ProfileSessionKey(controller.current!.scope, 'original'),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: ProfileWorkspaceScreen(
              createBotsSession: () => BotsSession((_) async => const []),
              controller: controller,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.settleMarkdown();
        if (!attachmentImage) {
          final download = find.byTooltip('Download');
          expect(download, findsOneWidget);
          await tester.ensureVisible(download);
          await tester.tap(download);
        }
        await tester.pump(const Duration(milliseconds: 100));
        expect(transport.requests, hasLength(1));
        expect(transport.requests.single.url.path, '/api/fs/download');
        expect(transport.requests.single.url.queryParameters, {
          'path': path,
          'profile': 'a',
          'session_id': 'original',
        });
        expect(transport.body.hasListener, isTrue);
        expect(transport.bodyCancelled, isFalse);
        expect(transport.closeCount, 0);

        // No deadline elapses; disposing the UI owner must stop this read now.
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(transport.bodyCancelled, isTrue);
        expect(transport.closeCount, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
