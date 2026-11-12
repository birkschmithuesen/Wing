import 'dart:async';
import 'package:wing/core/services/owned_remote_files.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wing/core/models/chat_output.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/remote_file_saver.dart';
import 'package:wing/core/services/remote_files_client.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/deliverable_attachment.dart';

class _Picker extends FilePickerPlatform {
  String? filename;
  Uint8List? data;
  Uri? destination;
  Object? error;
  Completer<Uri?>? pending;

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    filename = fileName;
    data = bytes;
    if (error != null) throw error!;
    return pending == null ? destination : await pending!.future;
  }
}

class _Files implements RemoteFilesDataSource {
  final pending = Completer<RemoteFileDownload>();
  @override
  Future<RemoteTextPreview> readText(
    String path, {
    required String profileName,
    required String storedSessionId,
  }) => throw UnimplementedError();
  @override
  Future<RemoteFileDownload> download(
    String path, {
    required String profileName,
    required String storedSessionId,
  }) => pending.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Picker picker;
  setUp(() {
    final original = FilePickerPlatform.instance;
    addTearDown(() => FilePickerPlatform.instance = original);
    picker = _Picker();
    FilePickerPlatform.instance = picker;
  });
  final file = RemoteFileDownload(
    filename: 'FULL_BANK_ANALYSIS.md',
    bytes: [35, 32, 65, 10],
  );

  test(
    'saves exact downloaded filename and bytes to the chosen destination',
    () async {
      picker.destination = Uri.parse('content://documents/report.md');
      expect(await saveRemoteFile(file), isTrue);
      expect(picker.filename, file.filename);
      expect(picker.data, file.bytes);
    },
  );
  test('cancelling the picker returns false', () async {
    expect(await saveRemoteFile(file), isFalse);
  });
  test('picker errors remain failures', () async {
    picker.error = PlatformException(code: 'write_failed');
    await expectLater(saveRemoteFile(file), throwsA(isA<PlatformException>()));
  });
  test('saves files larger than 32 MiB without a size gate', () async {
    picker.destination = Uri.parse('content://documents/delivery.zip');
    final largeFile = RemoteFileDownload(
      filename: 'delivery.zip',
      bytes: Uint8List(33 * 1024 * 1024),
    );
    expect(await saveRemoteFile(largeFile), isTrue);
    expect(picker.filename, largeFile.filename);
    expect(picker.data, same(largeFile.bytes));
  });

  for (final dark in [false, true]) {
    testWidgets(
      'file card saves 33 MiB with feedback through picker: dark=$dark',
      (tester) async {
        final response = Completer<http.Response>();
        picker.pending = Completer<Uri?>();
        final source = RemoteFilesClient(
          dashboard: DashboardClient(
            host: 'hermes.local',
            port: 9119,
            proxied: true,
            httpClient: MockClient((request) {
              expect(request.url.path, '/api/fs/download');
              expect(request.url.queryParameters['profile'], 'writer');
              expect(request.url.queryParameters['session_id'], 'chat-7');
              return response.future;
            }),
          ),
        );
        final owner = OwnedRemoteFiles(
          source: source,
          profileName: 'writer',
          storedSessionId: 'chat-7',
          release: source.close,
        );
        addTearDown(owner.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(dark ? Brightness.dark : Brightness.light),
            home: Scaffold(
              body: DeliverableAttachment(
                output: const ChatOutput(
                  kind: ChatOutputKind.file,
                  label: 'delivery.zip',
                  path: '/srv/delivery.zip',
                  url: null,
                ),
                onOpen: null,
                onDownload: (output) => owner.downloadAndSave(
                  output.path!,
                  admitPresentation: () => true,
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byTooltip('Download'));
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(picker.filename, isNull);

        response.complete(
          http.Response.bytes(
            Uint8List(33 * 1024 * 1024),
            200,
            headers: {
              'content-disposition': 'attachment; filename=delivery.zip',
            },
          ),
        );
        await tester.pump();
        expect(picker.filename, 'delivery.zip');
        expect(picker.data!.length, 33 * 1024 * 1024);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.text('File saved'), findsNothing);

        picker.pending!.complete(Uri.parse('content://documents/delivery.zip'));
        await tester.pumpAndSettle();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.text('File saved'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  test('empty files can be saved', () async {
    picker.destination = Uri.parse('content://documents/empty.txt');
    expect(
      await saveRemoteFile(
        RemoteFileDownload(filename: 'empty.txt', bytes: []),
      ),
      isTrue,
    );
    expect(picker.data, isEmpty);
  });

  test(
    'a held download rechecks route admission before opening a picker',
    () async {
      final source = _Files();
      var current = true;
      var releases = 0;
      final owner = OwnedRemoteFiles(
        source: source,
        profileName: 'captured-profile',
        storedSessionId: 'captured-chat',
        release: () => releases++,
      );
      final pending = owner.downloadAndSave(
        'report.txt',
        admitPresentation: () => current,
      );
      current = false;
      source.pending.complete(file);
      expect(await pending, isFalse);
      expect(picker.filename, isNull);
      owner.dispose();
      expect(releases, 1);
    },
  );
  for (final scenario in ['admitted', 'changed route', 'disposed owner']) {
    test(
      'resource sharing rechecks captured owner after download: $scenario',
      () async {
        final source = _Files();
        final owner = OwnedRemoteFiles(
          source: source,
          profileName: 'captured-profile',
          storedSessionId: 'captured-chat',
          release: () {},
        );
        var current = true;
        RemoteFileDownload? delivered;
        final pending = owner.downloadAndShare(
          'report.txt',
          admitPresentation: () => current,
          deliver: (file) async {
            delivered = file;
          },
        );
        if (scenario == 'changed route') current = false;
        if (scenario == 'disposed owner') owner.dispose();
        final completion = scenario == 'disposed owner'
            ? expectLater(pending, throwsStateError)
            : pending;
        source.pending.complete(file);
        await completion;
        expect(delivered, scenario == 'admitted' ? same(file) : isNull);
        owner.dispose();
      },
    );
  }
}
