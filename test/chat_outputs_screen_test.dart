import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/screens/html_preview_screen.dart';
import 'package:wing/core/services/chat_outputs_session.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:image/image.dart' as img;
import 'package:wing/core/models/chat_output.dart';
import 'package:wing/core/screens/chat_outputs_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/remote_files_client.dart';
import 'package:wing/core/services/android_file_delivery_service.dart';
import 'package:wing/core/services/media_preview_service.dart';
import 'package:wing/core/services/pdf_preview_service.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/widgets/source_code_block.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';
import 'package:wing/core/widgets/chat_inline_image.dart';
import 'package:wing/core/widgets/web_output_preview.dart';
import 'chat_inline_image_test.dart' show settleImages;
import 'package:wing/core/widgets/resource_filename.dart';
import 'package:wing/core/theme/wing_theme.dart';

class _FileDelivery extends AndroidFileDeliveryService {
  final Future<bool> Function(RemoteFileDownload file, String? mimeType) open;
  _FileDelivery(this.open);

  @override
  Future<bool> openInApp(RemoteFileDownload file, {String? mimeType}) =>
      open(file, mimeType);
}

class _MediaPreview extends MediaPreviewService {
  final Future<bool> Function(
    RemoteFileDownload file,
    String title,
    String? mimeType,
  )
  play;

  const _MediaPreview(this.play);

  @override
  bool supportsType(String filename, {String? mimeType}) => true;

  @override
  Future<bool> open(
    RemoteFileDownload file, {
    required String title,
    String? mimeType,
    Map<String, int>? appearance,
  }) => play(file, title, mimeType);
}

Widget _screen({
  required Future<List<Map<String, dynamic>>> Function() loadHistory,
  required Future<RemoteFileDownload> Function(String path) download,
  required Future<RemoteTextPreview> Function(String path) readText,
  Future<void> Function(RemoteFileDownload)? deliver,
  AndroidFileDeliveryService fileDelivery = const AndroidFileDeliveryService(),
  MediaPreviewService mediaPreview = const MediaPreviewService(),
}) => MaterialApp(
  home: ChatOutputsScreen(
    chatTitle: 'Only this chat',
    createSession: () => ChatOutputsSession(
      loadHistory: (offset) async => ProfileHistoryPage(
        'chat',
        await loadHistory(),
        offset,
        500,
        isComplete: true,
      ),
      download: download,
      readText: readText,
      deliver: deliver,
      fileDelivery: fileDelivery,
      mediaPreview: mediaPreview,
    ),
  ),
);

RemoteTextPreview _textPreview(String path) => RemoteTextPreview(
  path: path,
  text: 'void main() {}',
  language: 'dart',
  mimeType: 'text/plain',
  binary: false,
  truncated: false,
);

Finder _viewerAction(String label) => find.byWidgetPredicate(
  (widget) => widget is ResourceViewerAction && widget.label == label,
);

void main() {
  testWidgets(
    'older outputs keep their action label and usable reading stays quiet',
    (tester) async {
      final older = Completer<ProfileHistoryPage>();
      addTearDown(() {
        if (!older.isCompleted) {
          older.complete(
            ProfileHistoryPage('chat', const [], 500, 500, isComplete: true),
          );
        }
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ChatOutputsScreen(
            chatTitle: 'This chat',
            createSession: () => ChatOutputsSession(
              loadHistory: (offset) async => offset == 0
                  ? ProfileHistoryPage(
                      'chat',
                      [
                        {
                          'id': 501,
                          'role': 'assistant',
                          'content': 'Saved /srv/current/report.pdf',
                        },
                        for (var id = 502; id <= 1000; id++)
                          {
                            'id': id,
                            'role': 'assistant',
                            'content': 'Message $id',
                          },
                      ],
                      0,
                      500,
                    )
                  : older.future,
              download: (_) async => throw StateError('Unexpected download'),
              readText: (_) async => throw StateError('Unexpected preview'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Load older outputs'));
      await tester.pump();
      expect(find.text('Loading older outputs…'), findsNothing);
      expect(find.text('Load older outputs'), findsOneWidget);
      expect(find.bySemanticsLabel('Loading outputs'), findsNothing);
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Load older outputs'),
            )
            .onPressed,
        isNull,
      );
      older.complete(
        ProfileHistoryPage('chat', const [], 500, 500, isComplete: true),
      );
      await tester.pumpAndSettle();
      expect(find.byType(StudioLoading), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  const capture = bool.fromEnvironment('CAPTURE_RESOURCE_VIEWERS');
  setUpAll(() async {
    if (!capture) return;
    const root = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final (family, file) in [
      ('Roboto', 'Roboto-Regular.ttf'),
      ('MaterialIcons', 'MaterialIcons-Regular.otf'),
      ('monospace', 'DejaVuSansMono.ttf'),
    ]) {
      await (FontLoader(family)..addFont(
            File(
              '$root/$file',
            ).readAsBytes().then((b) => b.buffer.asByteData()),
          ))
          .load();
    }
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final intent in [
        'accessible header',
        'file path',
        'formatted copy',
        'raw copy',
      ]) {
        testWidgets('resource $intent ${brightness.name} $scale', (
          tester,
        ) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 780);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          const target =
              '/srv/projects/australia/sources/2026-10-08-perth-return-hotel-flight-gate.md';
          const source =
              '# Perth return-night hotel — wait for flight timing\n\nDecision recorded. **Wait for the flight timing** before selecting the hotel.\n\n- Early departure: check airport access.\n- Later departure: confirm transfer time.\n\n## Evidence\n\nKeep the recorded decision separate from assumptions.\n\nFurther details remain available by scrolling.\n\n';
          String? copied;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'Clipboard.setData') {
                copied = (call.arguments as Map)['text'] as String;
              }
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          final boundaryKey = GlobalKey();
          Future<void> captureViewer(String suffix) async {
            if (!capture) return;
            await tester.runAsync(() async {
              final boundary =
                  boundaryKey.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final rendered = await boundary.toImage(pixelRatio: 1);
              final png = await rendered.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                    'build/resource-viewers/${brightness.name}-${scale.toInt()}$suffix.png',
                  )
                  .create(recursive: true)
                  .then((file) => file.writeAsBytes(png!.buffer.asUint8List()));
              rendered.dispose();
            });
          }

          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(key: boundaryKey, child: child),
              ),
              home: ChatOutputsScreen(
                chatTitle: 'Fixture',
                initialOutput: const ChatOutput(
                  kind: ChatOutputKind.file,
                  path: target,
                  url: null,
                  label: '2026-10-08-perth-return-hotel-flight-gate.md',
                ),
                createSession: () => ChatOutputsSession(
                  loadHistory: (offset) async => ProfileHistoryPage(
                    'fixture',
                    const [],
                    offset,
                    500,
                    isComplete: true,
                  ),
                  download: (_) async =>
                      throw StateError('No fixture download'),
                  readText: (path) async => RemoteTextPreview(
                    path: target,
                    text: source,
                    language: 'markdown',
                    mimeType: 'text/markdown',
                    binary: false,
                    truncated: false,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final name = find.descendant(
            of: find.byType(ResourceFilename),
            matching: find.byType(Text),
          );
          expect(
            tester.widget<Text>(name).data,
            '2026-10-08-perth-return-hotel-flight-gate.md',
          );
          final toolbarActions = find.byType(ResourceViewerAction);
          expect(toolbarActions, findsNWidgets(4));
          final controls = toolbarActions
              .evaluate()
              .map((element) => find.byWidget(element.widget))
              .toList();
          final viewport =
              Offset.zero &
              (tester.view.physicalSize / tester.view.devicePixelRatio);
          for (var i = 0; i < controls.length; i++) {
            final button = controls[i];
            expect(button.hitTestable(), findsOneWidget);
            final bounds = tester.getRect(button);
            expect(bounds.width, greaterThan(0));
            expect(bounds.height, greaterThan(0));
            expect(viewport.intersect(bounds), bounds);
            for (var j = i + 1; j < controls.length; j++) {
              expect(bounds.overlaps(tester.getRect(controls[j])), isFalse);
            }
          }
          expect(find.byType(MarkdownMessageContent), findsOneWidget);
          expect(tester.takeException(), isNull);
          await captureViewer('');
          switch (intent) {
            case 'accessible header':
              expect(
                find.byTooltip('Copy content').hitTestable(),
                findsOneWidget,
              );
              expect(
                find.byTooltip('Show Raw content').hitTestable(),
                findsOneWidget,
              );
            case 'file path':
              await tester.tap(find.byTooltip('Show file path').last);
              await tester.pumpAndSettle();
              expect(find.text(target), findsOneWidget);
              await captureViewer('-path');
            case 'formatted copy':
              await tester.tap(find.byTooltip('Copy content'));
              await tester.pump();
              expect(copied, source);
            case 'raw copy':
              await tester.tap(find.byTooltip('Show Raw content'));
              await tester.pump();
              expect(find.byType(MarkdownMessageContent), findsNothing);
              expect(find.text(source), findsOneWidget);
              await captureViewer('-raw');
              await tester.tap(find.byTooltip('Copy content'));
              await tester.pump();
              expect(copied, source);
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
  testWidgets('downloaded image shares its exact bytes with a share glyph', (
    tester,
  ) async {
    final file = RemoteFileDownload(
      filename: 'server-photo.png',
      bytes: img.encodePng(
        img.Image(width: 4, height: 4)..clear(img.ColorRgb8(10, 30, 40)),
      ),
    );
    RemoteFileDownload? delivered;
    final downloads = <String>[];
    await tester.pumpWidget(
      _screen(
        loadHistory: () async => [
          {'role': 'assistant', 'content': 'Saved /srv/original/photo.png'},
        ],
        download: (path) async {
          downloads.add(path);
          return file;
        },
        readText: (_) async => throw StateError('Unexpected text read'),
        deliver: (value) async => delivered = value,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('photo.png'));
    await settleImages(tester);
    final action = tester.widget<ResourceViewerAction>(
      _viewerAction('Save or share'),
    );
    expect(action.icon, Icons.share_outlined);
    expect(find.text('Save or share'), findsNothing);
    await tester.tap(find.byTooltip('Save or share'));
    await tester.pumpAndSettle();
    expect(downloads, ['/srv/original/photo.png']);
    expect(delivered, same(file));
    expect(tester.takeException(), isNull);
  });
  testWidgets('report appendix resolves beside the document', (tester) async {
    const folder =
        '/home/tarkil/projects/memory-maintenance/reports/monthly-pilot-20260927';
    final reads = <String>[];
    await tester.pumpWidget(
      _screen(
        loadHistory: () async => [
          {'role': 'assistant', 'content': 'Saved $folder/report.md'},
        ],
        readText: (path) async {
          reads.add(path);
          if (path != '$folder/report.md' && path != '$folder/details.md') {
            throw const DashboardHttpException(404, 'fs/read-text');
          }
          final filler = List.filled(30, 'Earlier evidence.\n\n').join();
          final source = path.endsWith('/report.md')
              ? '[appendix](details.md#the-six-health-checks)'
              : '# Monthly pilot\n\n$filler## The six health checks\n\nAppendix contents\n\n'
                    '[Corrections](#exact-correction-targets)\n\n$filler'
                    '## Exact correction targets\n\nCorrection contents\n\n$filler';
          return RemoteTextPreview(
            path: path,
            text: source,
            language: 'markdown',
            mimeType: 'text/markdown',
            binary: false,
            truncated: false,
          );
        },
        download: (_) async => throw StateError('Unexpected download'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('report.md'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('appendix', findRichText: true));
    await tester.pumpAndSettle();
    expect(reads, ['$folder/report.md', '$folder/details.md']);
    expect(find.text('Appendix contents'), findsOneWidget);
    final contentTop = tester.getRect(find.byType(AppBar)).bottom;
    expect(
      tester.getRect(find.text('The six health checks')).top,
      inInclusiveRange(
        contentTop,
        tester.view.physicalSize.height / tester.view.devicePixelRatio,
      ),
    );
    await tester.tap(find.text('Corrections', findRichText: true));
    await tester.pumpAndSettle();
    expect(reads, ['$folder/report.md', '$folder/details.md']);
    expect(
      tester.getRect(find.text('Exact correction targets')).top,
      inInclusiveRange(
        contentTop,
        tester.view.physicalSize.height / tester.view.devicePixelRatio,
      ),
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('appendix', findRichText: true), findsOneWidget);
  });

  testWidgets('initial output opens directly without loading other history', (
    tester,
  ) async {
    var historyLoads = 0;
    String? previewPath;
    await tester.pumpWidget(
      MaterialApp(
        home: ChatOutputsScreen(
          chatTitle: 'Owned chat',
          initialOutput: const ChatOutput(
            kind: ChatOutputKind.file,
            path: '../exports/report.txt',
            url: null,
            label: 'report.txt',
          ),
          createSession: () => ChatOutputsSession(
            loadHistory: (_) async {
              historyLoads++;
              throw StateError('history must not load');
            },
            readText: (path) async {
              previewPath = path;
              return _textPreview(path);
            },
            download: (_) async => throw StateError('Unexpected download'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(historyLoads, 0);
    expect(previewPath, '../exports/report.txt');
    expect(find.byType(SourceCodeBlock), findsOneWidget);
  });

  testWidgets('initial output retries the same unavailable target', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChatOutputsScreen(
          chatTitle: 'Owned chat',
          initialOutput: const ChatOutput(
            kind: ChatOutputKind.file,
            path: '/srv/removed/report.txt',
            url: null,
            label: 'report.txt',
          ),
          createSession: () => ChatOutputsSession(
            loadHistory: (_) async => throw StateError('Unexpected history'),
            readText: (path) async {
              attempts++;
              if (attempts == 1) throw StateError('gone');
              return _textPreview(path);
            },
            download: (_) async => throw StateError('Unexpected download'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'This file could not be opened. Try again, or refresh the chat.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.byType(SourceCodeBlock), findsOneWidget);
  });

  testWidgets('initial output explains an HTTP access denial', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ChatOutputsScreen(
          chatTitle: 'Owned chat',
          initialOutput: const ChatOutput(
            kind: ChatOutputKind.file,
            path: '/srv/private/report.md',
            url: null,
            label: 'report.md',
          ),
          createSession: () => ChatOutputsSession(
            loadHistory: (_) async => throw StateError('Unexpected history'),
            readText: (_) async =>
                throw const DashboardHttpException(403, 'files/read'),
            download: (_) async => throw StateError('Unexpected download'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Hermes denied access to this file. Ask Hermes for an accessible copy.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'This file could not be opened. It may have moved or be unavailable on Hermes.',
      ),
      findsNothing,
    );
  });

  testWidgets('output preview explains a 404 without offering a retry', (
    tester,
  ) async {
    await tester.pumpWidget(
      _screen(
        loadHistory: () async => [
          {
            'role': 'assistant',
            'content': 'Saved /srv/current/export-review.md',
          },
        ],
        download: (_) async => throw StateError('Unexpected download'),
        readText: (_) async =>
            throw const DashboardHttpException(404, 'files/read'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('export-review.md'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Hermes could not find this file, or its file service is unavailable. Ask Hermes for a fresh download link.',
      ),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('output preview retries a temporary server failure', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      _screen(
        loadHistory: () async => [
          {
            'role': 'assistant',
            'content': 'Saved /srv/current/export-review.md',
          },
        ],
        download: (_) async => throw StateError('Unexpected download'),
        readText: (path) async {
          attempts++;
          if (attempts == 1) {
            throw const DashboardHttpException(503, 'files/read');
          }
          return _textPreview(path);
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('export-review.md'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Hermes could not open this file right now. Try again shortly.',
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Retry'), findsOneWidget);

    await tester.tap(find.byTooltip('Retry'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.byType(MarkdownMessageContent), findsOneWidget);
  });

  testWidgets('initial output Back to chat returns to its exact caller', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ChatOutputsScreen(
                    chatTitle: 'Original chat',
                    initialOutput: const ChatOutput(
                      kind: ChatOutputKind.file,
                      path: '/srv/removed/report.txt',
                      url: null,
                      label: 'report.txt',
                    ),
                    createSession: () => ChatOutputsSession(
                      loadHistory: (_) async =>
                          throw StateError('Unexpected history'),
                      readText: (_) async => throw StateError('gone'),
                      download: (_) async =>
                          throw StateError('Unexpected download'),
                    ),
                  ),
                ),
              ),
              child: const Text('Open owned output'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open owned output'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Back to chat'));
    await tester.pumpAndSettle();

    expect(find.text('Open owned output'), findsOneWidget);
    expect(find.text('Original chat'), findsNothing);
  });

  testWidgets('late initial response cannot open after returning to chat', (
    tester,
  ) async {
    final pending = Completer<RemoteTextPreview>();
    var started = false;
    addTearDown(() {
      if (!pending.isCompleted) {
        pending.complete(_textPreview('/srv/output/report.txt'));
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ChatOutputsScreen(
                    chatTitle: 'Original chat',
                    initialOutput: const ChatOutput(
                      kind: ChatOutputKind.file,
                      path: '/srv/output/report.txt',
                      url: null,
                      label: 'report.txt',
                    ),
                    createSession: () => ChatOutputsSession(
                      loadHistory: (_) async =>
                          throw StateError('Unexpected history'),
                      readText: (_) {
                        started = true;
                        return pending.future;
                      },
                      download: (_) async =>
                          throw StateError('Unexpected download'),
                    ),
                  ),
                ),
              ),
              child: const Text('Open owned output'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open owned output'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Back to chat'), findsOneWidget);
    expect(started, isTrue);
    await tester.tap(find.text('Back to chat'));
    await tester.pumpAndSettle();
    pending.complete(_textPreview('/srv/output/report.txt'));
    await tester.pumpAndSettle();

    expect(find.text('Open owned output'), findsOneWidget);
    expect(find.byType(SourceCodeBlock), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Read PDF keeps its original path and returns to file options', (
    tester,
  ) async {
    const channel = MethodChannel(PdfPreviewService.channelName);
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return switch (call.method) {
        'open' => {'documentId': 'from-output', 'pageCount': 1},
        'render' => Uint8List(0),
        _ => null,
      };
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    String? downloadedPath;
    await tester.pumpWidget(
      _screen(
        loadHistory: () async => [
          {'role': 'assistant', 'content': 'Saved /srv/current/report.pdf'},
        ],
        readText: (path) async => RemoteTextPreview(
          path: path,
          text: '',
          language: '',
          mimeType: 'application/pdf',
          binary: true,
          truncated: false,
        ),
        download: (path) async {
          downloadedPath = path;
          return RemoteFileDownload(
            filename: 'report.pdf',
            bytes: [37, 80, 68, 70],
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('report.pdf'));
    await tester.pumpAndSettle();
    expect(downloadedPath, isNull);
    await tester.tap(find.byTooltip('Read PDF'));
    await tester.pumpAndSettle();
    expect(downloadedPath, '/srv/current/report.pdf');
    expect(calls.first.arguments, {
      'bytes': Uint8List.fromList([37, 80, 68, 70]),
    });
    expect(
      find.textContaining('This PDF could not be displayed'),
      findsOneWidget,
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(calls.last.method, 'close');
    expect(calls.last.arguments, {'documentId': 'from-output'});
    expect(find.byTooltip('Open in app'), findsOneWidget);
    expect(find.byTooltip('Save or share'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('PDF open uses original download and keeps save/share fallback', (
    tester,
  ) async {
    RemoteFileDownload? opened;
    String? mime;
    String? path;
    await tester.pumpWidget(
      _screen(
        loadHistory: () async => [
          {'role': 'assistant', 'content': 'Saved /srv/current/report.pdf'},
        ],
        readText: (path) async => RemoteTextPreview(
          path: path,
          text: '',
          language: '',
          mimeType: 'application/pdf',
          binary: true,
          truncated: false,
        ),
        download: (value) async {
          path = value;
          return RemoteFileDownload(
            filename: 'actual.pdf',
            bytes: [37, 80, 68, 70],
          );
        },
        fileDelivery: _FileDelivery((file, type) async {
          opened = file;
          mime = type;
          return false;
        }),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('report.pdf'));
    await tester.pumpAndSettle();
    expect(opened, isNull);
    await tester.tap(find.byTooltip('Open in app'));
    await tester.pumpAndSettle();
    expect(path, '/srv/current/report.pdf');
    expect(opened?.filename, 'actual.pdf');
    expect(opened?.bytes, [37, 80, 68, 70]);
    expect(mime, 'application/pdf');
    expect(
      find.text('No compatible app was found. Use Save or share instead.'),
      findsOneWidget,
    );
    expect(find.byTooltip('Save or share'), findsOneWidget);
  });

  testWidgets('closing preview during download prevents a late app launch', (
    tester,
  ) async {
    final pending = Completer<RemoteFileDownload>();
    var opened = false;
    await tester.pumpWidget(
      _screen(
        loadHistory: () async => [
          {'role': 'assistant', 'content': 'Saved /srv/current/report.pdf'},
        ],
        readText: (path) async => RemoteTextPreview(
          path: path,
          text: '',
          language: '',
          mimeType: 'application/pdf',
          binary: true,
          truncated: false,
        ),
        download: (_) => pending.future,
        fileDelivery: _FileDelivery((_, _) async {
          opened = true;
          return true;
        }),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('report.pdf'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open in app'));
    await tester.pump();
    expect(
      tester
          .widget<ResourceViewerAction>(_viewerAction('Open in app'))
          .onPressed,
      isNull,
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    pending.complete(
      RemoteFileDownload(filename: 'report.pdf', bytes: [37, 80, 68, 70]),
    );
    await tester.pumpAndSettle();
    expect(opened, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('media playback downloads the original path and exact bytes', (
    tester,
  ) async {
    String? downloadedPath;
    RemoteFileDownload? played;
    String? title;
    String? mimeType;
    await tester.pumpWidget(
      _screen(
        loadHistory: () async => [
          {'role': 'assistant', 'content': 'Saved /srv/current/clip.mp4'},
        ],
        readText: (path) async => RemoteTextPreview(
          path: path,
          text: '',
          language: '',
          mimeType: 'video/mp4',
          binary: true,
          truncated: false,
        ),
        download: (path) async {
          downloadedPath = path;
          return RemoteFileDownload(
            filename: 'server-clip.mp4',
            bytes: [1, 2, 3],
          );
        },
        mediaPreview: _MediaPreview((file, value, type) async {
          played = file;
          title = value;
          mimeType = type;
          return true;
        }),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('clip.mp4'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Play media'));
    await tester.pumpAndSettle();

    expect(downloadedPath, '/srv/current/clip.mp4');
    expect(played?.filename, 'server-clip.mp4');
    expect(played?.bytes, orderedEquals([1, 2, 3]));
    expect(title, 'clip.mp4');
    expect(mimeType, 'video/mp4');
    expect(find.byTooltip('Save or share'), findsOneWidget);
  });

  testWidgets('media playback guard blocks duplicates and closed previews', (
    tester,
  ) async {
    var downloads = 0;
    var plays = 0;
    var pending = Completer<RemoteFileDownload>();
    await tester.pumpWidget(
      _screen(
        loadHistory: () async => [
          {'role': 'assistant', 'content': 'Saved /srv/current/clip.mp4'},
        ],
        readText: (path) async => RemoteTextPreview(
          path: path,
          text: '',
          language: '',
          mimeType: 'video/mp4',
          binary: true,
          truncated: false,
        ),
        download: (_) {
          downloads++;
          return pending.future;
        },
        mediaPreview: _MediaPreview((_, _, _) async {
          plays++;
          return true;
        }),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('clip.mp4'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Play media'));
    await tester.tap(find.byTooltip('Play media'));
    await tester.pump();
    expect(downloads, 1);
    expect(
      tester
          .widget<ResourceViewerAction>(_viewerAction('Play media'))
          .onPressed,
      isNull,
    );

    await tester.pageBack();
    await tester.pumpAndSettle();
    pending.complete(
      RemoteFileDownload(filename: 'server-clip.mp4', bytes: [1, 2, 3]),
    );
    await tester.pumpAndSettle();
    expect(plays, 0);
  });

  testWidgets(
    'authenticated SVG output uses its original path and shared viewer',
    (tester) async {
      String? downloadedPath;
      const source =
          '<svg xmlns="http://www.w3.org/2000/svg"><text>Hi</text></svg>';
      final nativeCalls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        (call) async {
          nativeCalls.add(call);
          if (call.method == 'create') return 1;
          if (call.method == 'resize') {
            final args = call.arguments as Map;
            return {'width': args['width'], 'height': args['height']};
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          null,
        ),
      );
      await tester.pumpWidget(
        _screen(
          loadHistory: () async => [
            {'role': 'assistant', 'content': 'Saved /srv/current/chart.svg'},
          ],
          readText: (_) async => throw StateError('Unexpected text preview'),
          download: (path) async {
            downloadedPath = path;
            return RemoteFileDownload(
              filename: 'server-chart.svg',
              bytes: utf8.encode(source),
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('chart.svg'));
      await tester.pumpAndSettle();

      expect(downloadedPath, '/srv/current/chart.svg');
      expect(find.byType(WebOutputPreview), findsOneWidget);
      expect(find.byType(AndroidView), findsOneWidget);
      expect(find.byTooltip('Save or share'), findsOneWidget);
      await tester.tap(find.byTooltip('Show source'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SourceCodeBlock>(find.byType(SourceCodeBlock)).code,
        source,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('chart.svg'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'HTML preview opens rendered full original directly, even when text is truncated',
    (tester) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      String? downloadedPath;
      const source =
          '<!doctype html><style>p{color:red}</style><p>Full file</p>';
      final nativeCalls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        (call) async {
          nativeCalls.add(call);
          if (call.method == 'create') return 1;
          if (call.method == 'resize') {
            final args = call.arguments as Map;
            return {'width': args['width'], 'height': args['height']};
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          null,
        ),
      );
      await tester.pumpWidget(
        _screen(
          loadHistory: () async => [
            {'role': 'assistant', 'content': 'Saved /srv/current/page.txt'},
          ],
          readText: (path) async => RemoteTextPreview(
            path: path,
            text: '<p>short preview</p>',
            language: 'html',
            mimeType: 'text/html; charset=utf-8',
            binary: false,
            truncated: true,
          ),
          download: (path) async {
            downloadedPath = path;
            return RemoteFileDownload(
              filename: 'page.html',
              bytes: utf8.encode(source),
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('page.txt'));
      await tester.pumpAndSettle();
      expect(
        find.text('Preview shortened by Hermes. Save the file to read it all.'),
        findsNothing,
      );
      expect(downloadedPath, '/srv/current/page.txt');
      expect(find.byType(WebOutputPreview), findsOneWidget);
      final create = nativeCalls.singleWhere((call) => call.method == 'create');
      final args = create.arguments as Map;
      expect(
        const StandardMessageCodec().decodeMessage(
          ByteData.sublistView(args['params'] as Uint8List),
        ),
        allOf(
          containsPair('source', source),
          containsPair('dark', false),
          containsPair('format', 'html'),
          containsPair(
            'palette',
            containsPair(
              'accent',
              Theme.of(
                tester.element(find.byType(AndroidView)),
              ).colorScheme.primary.toARGB32(),
            ),
          ),
        ),
      );
      expect(find.byTooltip('Save or share'), findsOneWidget);
      await tester.tap(find.byTooltip('Show source'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SourceCodeBlock>(find.byType(SourceCodeBlock)).code,
        source,
      );
      expect(find.byTooltip('Show HTML'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Outputs · Only this chat'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('closing HTML preview prevents a late native view', (
    tester,
  ) async {
    var downloads = 0;
    final pending = Completer<RemoteFileDownload>();
    final nativeCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (call) async {
        nativeCalls.add(call);
        return call.method == 'create' ? 1 : null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        null,
      ),
    );
    await tester.pumpWidget(
      _screen(
        loadHistory: () async => [
          {'role': 'assistant', 'content': 'Saved /srv/current/page.html'},
        ],
        readText: (path) async => RemoteTextPreview(
          path: path,
          text: '<p>preview</p>',
          language: 'html',
          mimeType: 'text/html',
          binary: false,
          truncated: false,
        ),
        download: (_) {
          downloads++;
          return pending.future;
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('page.html'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(downloads, 1);
    expect(
      find.descendant(
        of: find.byType(HtmlPreviewScreen),
        matching: find.byType(StudioLoading),
      ),
      findsOneWidget,
    );
    expect(find.text('Open HTML'), findsNothing);
    await tester.pump(const Duration(milliseconds: 400));
    expect(downloads, 1);
    await tester.pageBack();
    await tester.pumpAndSettle();
    pending.complete(
      RemoteFileDownload(
        filename: 'page.html',
        bytes: utf8.encode('<p>full</p>'),
      ),
    );
    await tester.pumpAndSettle();
    expect(nativeCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('oversized HTML reports its preview cap before decoding', (
    tester,
  ) async {
    await tester.pumpWidget(
      _screen(
        loadHistory: () async => [
          {'role': 'assistant', 'content': 'Saved /srv/current/page.htm'},
        ],
        readText: (path) async => RemoteTextPreview(
          path: path,
          text: '<p>preview</p>',
          language: 'text',
          mimeType: 'text/plain',
          binary: false,
          truncated: true,
        ),
        download: (_) async => RemoteFileDownload(
          filename: 'page.htm',
          bytes: List.filled(WebOutputPreview.maxHtmlSourceLength + 1, 0xff),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('page.htm'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'This HTML file is too large to preview. Use Save or share to open it in another app.',
      ),
      findsOneWidget,
    );
    expect(find.byType(WebOutputPreview), findsNothing);
  });

  testWidgets('shows supplied chat outputs and previews the original path', (
    tester,
  ) async {
    String? readPath;
    await tester.pumpWidget(
      _screen(
        loadHistory: () async => [
          {'role': 'assistant', 'content': 'Saved /srv/current/notes.md'},
          {
            'role': 'user',
            'content': 'Another chat mentioned /srv/other/report.pdf',
          },
        ],
        download: (_) async => throw StateError('Unexpected download'),
        readText: (path) async {
          readPath = path;
          return _textPreview(path);
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('notes.md'), findsOneWidget);
    expect(find.text('report.pdf'), findsNothing);

    await tester.tap(find.text('notes.md'));
    await tester.pumpAndSettle();

    expect(readPath, '/srv/current/notes.md');
    expect(find.byType(MarkdownMessageContent), findsOneWidget);
    expect(find.bySubtype<MarkdownBody>(), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Outputs · Only this chat'), findsOneWidget);
    expect(find.text('notes.md'), findsOneWidget);
  });

  testWidgets(
    'markdown preview is formatted without chat chrome and source stays exact',
    (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      const source =
          '# Release notes\n\n**Ready**\n\n![Remote](https://example.com/a.png)';
      await tester.pumpWidget(
        _screen(
          loadHistory: () async => [
            {'role': 'assistant', 'content': 'Saved /srv/current/notes.md'},
          ],
          readText: (path) async => RemoteTextPreview(
            path: path,
            text: source,
            language: 'text',
            mimeType: 'text/plain',
            binary: false,
            truncated: true,
          ),
          download: (_) async => throw StateError('Unexpected download'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('notes.md'));
      await tester.pumpAndSettle();

      expect(find.byType(MarkdownMessageContent), findsOneWidget);
      expect(find.bySubtype<MarkdownBody>(), findsOneWidget);
      expect(find.text('Release notes'), findsOneWidget);
      expect(find.text('Hermes'), findsNothing);
      expect(find.byType(ChatInlineImage), findsOneWidget);
      expect(find.byTooltip('Share file'), findsOneWidget);
      expect(find.text('Copy content'), findsNothing);
      expect(find.text('Save or share'), findsNothing);
      await tester.tap(find.byTooltip('Copy content'));
      await tester.pump();
      expect(copied, source);
      expect(
        find.text('Preview shortened by Hermes. Save the file to read it all.'),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Show Raw content'));
      await tester.pump();
      expect(find.byType(MarkdownMessageContent), findsNothing);
      expect(find.text(source), findsOneWidget);
      expect(find.byTooltip('Show formatted content'), findsOneWidget);
      expect(find.byTooltip('Share file'), findsOneWidget);
      expect(find.text('Save or share'), findsNothing);
      await tester.tap(find.byTooltip('Copy content'));
      await tester.pump();
      expect(copied, source);

      await tester.tap(find.byTooltip('Show formatted content'));
      await tester.pump();
      expect(find.byType(MarkdownMessageContent), findsOneWidget);
    },
  );

  testWidgets(
    'markdown preview opens an explicit Hermes file and returns to its source',
    (tester) async {
      final readPaths = <String>[];
      await tester.pumpWidget(
        _screen(
          loadHistory: () async => [
            {'role': 'assistant', 'content': 'Saved /srv/current/notes.md'},
          ],
          readText: (path) async {
            readPaths.add(path);
            if (path == '/srv/current/notes.md') {
              const source =
                  '# Notes\n\n[Open report](/srv/current/report.txt)';
              return RemoteTextPreview(
                path: path,
                text: source,
                language: 'markdown',
                mimeType: 'text/markdown',
                binary: false,
                truncated: false,
              );
            }
            return RemoteTextPreview(
              path: path,
              text: 'Scoped report contents',
              language: 'text',
              mimeType: 'text/plain',
              binary: false,
              truncated: false,
            );
          },
          download: (_) async => throw StateError('Unexpected download'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('notes.md'));
      await tester.pumpAndSettle();
      expect(readPaths, ['/srv/current/notes.md']);

      await tester.tap(find.text('Open report', findRichText: true));
      await tester.pumpAndSettle();

      expect(readPaths, ['/srv/current/notes.md', '/srv/current/report.txt']);
      expect(
        tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!.text,
        'Scoped report contents',
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Notes'), findsOneWidget);
      expect(find.text('Open report'), findsOneWidget);
      expect(find.text('Outputs · Only this chat'), findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Outputs · Only this chat'), findsOneWidget);
      expect(find.text('notes.md'), findsOneWidget);
    },
  );

  testWidgets('Markdown share icon retains pending and retry behavior', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 780);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final firstDownload = Completer<RemoteFileDownload>();
    var downloads = 0;
    RemoteFileDownload? delivered;
    final file = RemoteFileDownload(
      filename: 'notes.md',
      bytes: utf8.encode('# Notes'),
    );
    await tester.pumpWidget(
      _screen(
        loadHistory: () async => [
          {'role': 'assistant', 'content': 'Saved /srv/notes.md'},
        ],
        readText: (path) async => RemoteTextPreview(
          path: path,
          text: '# Notes',
          language: 'markdown',
          mimeType: 'text/markdown',
          binary: false,
          truncated: false,
        ),
        download: (path) async {
          expect(path, '/srv/notes.md');
          downloads++;
          return downloads == 1 ? firstDownload.future : file;
        },
        deliver: (value) async {
          delivered = value;
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('notes.md'));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.text('notes.md')).bottom,
      lessThan(tester.getRect(find.byTooltip('Share file')).top),
    );
    final share = find.byTooltip('Share file');
    IconButton button() => tester.widget<IconButton>(
      find.ancestor(of: share, matching: find.byType(IconButton)).first,
    );
    await tester.tap(share);
    await tester.pump();
    expect(button().onPressed, isNull);
    firstDownload.completeError(StateError('Unavailable'));
    await tester.pumpAndSettle();
    expect(button().onPressed, isNotNull);
    expect(delivered, isNull);
    await tester.tap(share);
    await tester.pumpAndSettle();
    expect(downloads, 2);
    expect(delivered, same(file));
    expect(button().onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  for (final sample in [
    (language: 'md', mimeType: 'text/plain', binary: false),
    (language: 'text', mimeType: 'text/markdown; charset=utf-8', binary: false),
    (language: 'markdown', mimeType: 'text/plain', binary: true),
  ]) {
    testWidgets('Markdown admission for $sample', (tester) async {
      await tester.pumpWidget(
        _screen(
          loadHistory: () async => [
            {'role': 'assistant', 'content': 'Saved /srv/current/notes.txt'},
          ],
          readText: (path) async => RemoteTextPreview(
            path: path,
            text: '# Heading',
            language: sample.language,
            mimeType: sample.mimeType,
            binary: sample.binary,
            truncated: false,
          ),
          download: (_) async => throw StateError('Unexpected download'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('notes.txt'));
      await tester.pumpAndSettle();
      expect(
        find.byType(MarkdownMessageContent),
        sample.binary ? findsNothing : findsOneWidget,
      );
      expect(
        find.byTooltip('Show Raw content'),
        sample.binary ? findsNothing : findsOneWidget,
      );
      if (sample.binary) {
        expect(find.byTooltip('Save or share'), findsOneWidget);
      } else {
        expect(find.text('Heading'), findsOneWidget);
      }
    });
  }

  testWidgets('delivers the downloaded filename and exact bytes', (
    tester,
  ) async {
    String? downloadPath;
    RemoteFileDownload? delivered;
    await tester.pumpWidget(
      _screen(
        loadHistory: () async => [
          {'role': 'assistant', 'content': 'Saved /srv/current/report.pdf'},
        ],
        download: (path) async {
          downloadPath = path;
          return RemoteFileDownload(
            filename: 'server-report.pdf',
            bytes: [0, 1, 127, 255],
          );
        },
        readText: (_) async => throw StateError('Unexpected preview'),
        deliver: (download) async => delivered = download,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Save or share report.pdf'));
    await tester.pumpAndSettle();

    expect(downloadPath, '/srv/current/report.pdf');
    expect(delivered?.filename, 'server-report.pdf');
    expect(delivered?.bytes, orderedEquals([0, 1, 127, 255]));
  });

  testWidgets('shows loading, empty, and failure states', (tester) async {
    final firstLoad = Completer<List<Map<String, dynamic>>>();
    final failedRefresh = Completer<List<Map<String, dynamic>>>();
    var loads = 0;
    await tester.pumpWidget(
      _screen(
        loadHistory: () {
          loads++;
          if (loads == 1) return firstLoad.future;
          if (loads == 2) return failedRefresh.future;
          return Future.value([]);
        },
        download: (_) async => throw StateError('Unexpected download'),
        readText: (_) async => throw StateError('Unexpected preview'),
      ),
    );

    await tester.pump();
    expect(find.byType(StudioLoading), findsOneWidget);
    firstLoad.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('No files or links found in this chat.'), findsOneWidget);

    await tester.tap(find.byTooltip('Refresh outputs'));
    await tester.pump();
    failedRefresh.completeError(StateError('Profile unavailable.'));
    await tester.pumpAndSettle();
    expect(find.text('Profile unavailable.'), findsNothing);
    expect(find.textContaining('Check the Hermes connection'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Back to chat'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('No files or links found in this chat.'), findsOneWidget);
    expect(loads, 3);
  });

  testWidgets('reports denied file access on a narrow 200 percent layout', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: ChatOutputsScreen(
            chatTitle: 'Only this chat',
            createSession: () => ChatOutputsSession(
              loadHistory: (offset) async => ProfileHistoryPage(
                'chat',
                [
                  {
                    'role': 'assistant',
                    'content': 'Saved /srv/current/very-long-report-name.pdf',
                  },
                ],
                offset,
                500,
                isComplete: true,
              ),
              download: (_) async =>
                  throw const DashboardHttpException(403, 'fs/download'),
              readText: (_) async => throw StateError('Unexpected preview'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Save or share very-long-report-name.pdf'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Hermes denied access to this file. Ask Hermes for an accessible copy.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
