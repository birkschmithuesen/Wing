import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wing/core/screens/chat_outputs_screen.dart';
import 'package:wing/core/services/chat_outputs_session.dart';
import 'package:wing/core/services/remote_files_client.dart';
import 'package:wing/core/services/owned_remote_files.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/widgets/source_code_text.dart';
import 'package:wing/core/models/transcript_message.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/chat_output.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/deliverable_attachment.dart';
import 'package:wing/core/widgets/chat_inline_image.dart';
import 'package:wing/core/widgets/profile_message.dart';

import 'helpers/pump_markdown_widget.dart';

const reportPath =
    '/home/tarkil/projects/memory-maintenance/evaluation/FULL_BANK_ANALYSIS.md';
const htmlReportPath =
    '/home/tarkil/projects/memory-maintenance/reports/whole-bank-visual-20260928/index.html';

Widget message(
  String text, {
  Future<void> Function(ChatOutput)? open,
  Future<bool> Function(ChatOutput)? download,
}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: ProfileMessage(
        message: TranscriptMessage.fromRow({
          'role': 'assistant',
          'content': text,
        }),
        onOpenRemoteFile: open,
        onDownloadRemoteFile: download,
      ),
    ),
  ),
);

void main() {
  setUpAll(() async {
    if (!const bool.fromEnvironment('CAPTURE_DELIVERABLES')) return;
    const directory = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      'Roboto': 'Roboto-Regular.ttf',
      'monospace': 'RobotoMono-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(
              '$directory/${entry.value}',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });

  testWidgets('explicit Markdown file opens from its message through HTTP', (
    tester,
  ) async {
    const path = '/srv/README.md';
    const suffix = '/hermes-button-actions/contents/README.md';
    final response = Completer<http.Response>();
    final requests = <Uri>[];
    final client = RemoteFilesClient(
      dashboard: DashboardClient(
        host: 'hermes.test',
        port: 9119,
        proxied: true,
        httpClient: MockClient((request) {
          requests.add(request.url);
          expect(request.url.path, '/api/fs/read-text');
          expect(request.url.queryParameters, {
            'path': path,
            'profile': 'default',
            'session_id': 'origin-chat',
          });
          return response.future;
        }),
      ),
    );
    final files = OwnedRemoteFiles(
      source: client,
      profileName: 'default',
      storedSessionId: 'origin-chat',
      release: client.close,
    );
    addTearDown(files.dispose);
    await tester.pumpMarkdownWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: SingleChildScrollView(
              child: ProfileMessage(
                message: TranscriptMessage.fromRow(const {
                  'role': 'assistant',
                  'content':
                      'Request ending in `$suffix`.\n\n[Read the file]($path)',
                }),
                onOpenRemoteFile: (output) => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => ChatOutputsScreen(
                      chatTitle: 'Original chat',
                      initialOutput: output,
                      createSession: () => ChatOutputsSession(
                        loadHistory: (_) async =>
                            throw StateError('Unexpected history read'),
                        readText: files.readText,
                        download: files.download,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(DeliverableAttachment), findsOneWidget);
    expect(find.textContaining(suffix, findRichText: true), findsOneWidget);
    await tester.tap(find.byTooltip('Open preview'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(ChatOutputsScreen), findsOneWidget);
    expect(find.byType(StudioLoading), findsOneWidget);
    expect(tester.getSize(find.byType(StudioLoading)), const Size(18, 18));
    expect(requests, hasLength(1));
    response.complete(
      http.Response(
        jsonEncode({
          'path': path,
          'text': '# A real Markdown document',
          'language': 'markdown',
          'mimeType': 'text/markdown',
          'binary': false,
          'truncated': false,
        }),
        200,
      ),
    );
    await tester.pumpAndSettle();
    await tester.settleMarkdown();
    expect(
      find.textContaining('A real Markdown document', findRichText: true),
      findsWidgets,
    );
    expect(find.byType(StudioLoading), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'MEDIA report offers separate preview and download; copying stays exact',
    (tester) async {
      const source = '**Deliverable**\n\nMEDIA:$reportPath\n\nNext steps.';
      String? opened;
      String? downloaded;
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'];
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
      await tester.pumpMarkdownWidget(
        message(
          source,
          open: (output) async => opened = output.path,
          download: (output) async {
            downloaded = output.path;
            return true;
          },
        ),
      );
      expect(find.byType(DeliverableAttachment), findsOneWidget);
      expect(find.text('FULL_BANK_ANALYSIS.md'), findsOneWidget);
      await tester.tap(find.byTooltip('Open preview'));
      await tester.pumpAndSettle();
      expect(opened, reportPath);
      expect(downloaded, isNull);
      await tester.tap(find.byTooltip('Download'));
      await tester.pumpAndSettle();
      expect(downloaded, reportPath);
      expect(find.text('File saved'), findsOneWidget);
      await tester.tap(find.byTooltip('Copy message'));
      await tester.pump();
      expect(copied, source);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('explicit report links open independently and copy verbatim', (
    tester,
  ) async {
    const report =
        '/home/tarkil/projects/memory-maintenance/reports/monthly-pilot-20260927/report.md';
    const questions =
        '/home/tarkil/projects/memory-maintenance/evaluation/private/monthly-pilot-20260927-151620/case-review.md';
    const source =
        '**Report**\n\nThe dashboard is here:\n\n[Report]($report)\n\n'
        'The private question sheet is here:\n\n[Questions]($questions)';
    final opened = <String>[];
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'];
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
    await tester.pumpMarkdownWidget(
      message(source, open: (output) async => opened.add(output.path!)),
    );
    expect(find.byType(DeliverableAttachment), findsNWidgets(2));
    expect(find.text('report.md'), findsOneWidget);
    expect(find.text('case-review.md'), findsOneWidget);
    for (var index = 0; index < 2; index++) {
      final action = find.byTooltip('Open preview').at(index);
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
    }
    expect(opened, [report, questions]);
    await tester.ensureVisible(find.byTooltip('Copy message'));
    await tester.tap(find.byTooltip('Copy message'));
    await tester.pump();
    expect(copied, source);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'API request suffix stays literal ${brightness.name} scale $scale',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          const suffix = '/hermes-button-actions/contents/README.md';
          const source =
              'Please approve the request in '
              '[OneCLI](https://example.test) ending in:\n\n`$suffix`';
          final boundary = GlobalKey();
          String? copied;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'Clipboard.setData') {
                copied = (call.arguments as Map)['text'];
              }
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          await tester.pumpMarkdownWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: RepaintBoundary(
                key: boundary,
                child: Scaffold(
                  body: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: ProfileMessage(
                      message: TranscriptMessage.fromRow(const {
                        'role': 'assistant',
                        'content': source,
                      }),
                      onOpenRemoteFile: (_) async => fail('Code opened a file'),
                      onDownloadRemoteFile: (_) async =>
                          fail('Code downloaded a file'),
                    ),
                  ),
                ),
              ),
            ),
          );
          expect(find.byType(DeliverableAttachment), findsNothing);
          expect(
            find.textContaining(suffix, findRichText: true),
            findsOneWidget,
          );
          expect(find.byTooltip('Open preview'), findsNothing);
          expect(find.byTooltip('Download'), findsNothing);
          await tester.tap(find.byTooltip('Copy message'));
          await tester.pump();
          expect(copied, source);
          expect(tester.takeException(), isNull);
          if (const bool.fromEnvironment('CAPTURE_DELIVERABLES')) {
            await tester.runAsync(() async {
              final image =
                  await (boundary.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary)
                      .toImage();
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                'build/deliverables-review/code-${brightness.name}-$scale.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(data!.buffer.asUint8List());
              image.dispose();
            });
          }
        },
      );
    }
  }

  for (final path in [
    '/api/files/report.md',
    '/repos/owner/repo/contents/README.md',
    '/srv/report.md',
    '/srv/report.html',
    '~/reports/report.md',
    '../reports/report.md',
    r'C:\Users\a\report.md',
  ]) {
    testWidgets('file-shaped code stays literal: $path', (tester) async {
      await tester.pumpMarkdownWidget(message('`$path`', open: (_) async {}));
      expect(find.byType(DeliverableAttachment), findsNothing);
      expect(find.textContaining(path, findRichText: true), findsOneWidget);
    });
  }

  final references = {
    htmlReportPath: htmlReportPath,
    'Open ($htmlReportPath).': htmlReportPath,
    'Saved $htmlReportPath. Open it.': htmlReportPath,
    '**$htmlReportPath**': htmlReportPath,
    '/srv/index.htm': '/srv/index.htm',
    '~/reports/index.HTML': '~/reports/index.HTML',
    './reports/index.html': './reports/index.html',
    '../reports/index.html': '../reports/index.html',
    r'C:\reports\index.html': r'C:\reports\index.html',
    '/srv/report%23final.html': '/srv/report%23final.html',
    '[HTML report]($htmlReportPath)': htmlReportPath,
    'MEDIA:$htmlReportPath': htmlReportPath,
    'MEDIA:/srv/My report.pdf': '/srv/My report.pdf',
    'MEDIA: "/srv/final report.custom"': '/srv/final report.custom',
    '`MEDIA:/srv/report.md`': '/srv/report.md',
    'MEDIA:/srv/report%23final.md': '/srv/report%23final.md',
    'MEDIA:"/srv/report#final?.md"': '/srv/report#final?.md',
    '[Report](</srv/final report.md>)': '/srv/final report.md',
    '[**Report**](/srv/report%23final.md)': '/srv/report#final.md',
    '[Report](../exports/report.pdf)': '../exports/report.pdf',
    '[Report][file]\n\n[file]: /srv/report.md': '/srv/report.md',
    'MEDIA:file:///srv/report.md': '/srv/report.md',
    r'MEDIA:C:\Users\a\report.md': r'C:\Users\a\report.md',
  };
  for (final entry in references.entries) {
    testWidgets('remote target ${entry.key}', (tester) async {
      String? path;
      await tester.pumpMarkdownWidget(
        message(entry.key, open: (output) async => path = output.path),
      );
      await tester.tap(find.byTooltip('Open preview'));
      await tester.pumpAndSettle();
      expect(path, entry.value);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('plain HTML paths do not capture URLs, code or other filenames', (
    tester,
  ) async {
    await tester.pumpMarkdownWidget(
      message(
        'https://example.com/index.html\n\n'
        '[Website](https://example.com/index.html)\n\n'
        '`cat /srv/index.html`\n\n'
        '```text\n/srv/index.html\n```\n\n'
        'index.html and /srv/index.html.bak and /srv/index.html/assets\n\n'
        'project/reports/index.html and /srv/reports/',
        open: (_) async {},
      ),
    );
    expect(find.byType(DeliverableAttachment), findsNothing);
    expect(find.textContaining('Website', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'prose, lists, code, web links, and images retain their semantics',
    (tester) async {
      await tester.pumpMarkdownWidget(
        message(
          'Before [report](/srv/report.md) after.\n\n'
          '- First\n- [Second](/srv/second.md)\n\n'
          '```text\nMEDIA:/srv/example.md\n```\n\n'
          '`cat /srv/plain.md` and `/srv/reports/` and ` `\n\n'
          '[Website](https://example.com) and ![Image](https://example.com/image.png)\n\n'
          'MEDIA:unsupported:value',
          open: (_) async {},
        ),
      );
      expect(find.byType(DeliverableAttachment), findsNWidgets(2));
      expect(find.textContaining('Before'), findsOneWidget);
      expect(find.textContaining('after.'), findsOneWidget);
      expect(find.textContaining('First'), findsOneWidget);
      expect(
        find.textContaining('Website', findRichText: true),
        findsOneWidget,
      );
      expect(find.byType(ChatInlineImage), findsOneWidget);
      expect(
        tester.widget<ChatInlineImage>(find.byType(ChatInlineImage)).title,
        'Image',
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SourceCodeText &&
              widget.text.contains('MEDIA:/srv/example.md'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('MEDIA:unsupported:value'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('repeated file references and table links remain usable', (
    tester,
  ) async {
    final opened = <String>[];
    await tester.pumpMarkdownWidget(
      message(
        '[First](/srv/report.md) and [Again](/srv/report.md)\n\n'
        '| Report |\n| --- |\n| [Read](/srv/report.md) |',
        open: (output) async => opened.add(output.path!),
      ),
    );
    expect(find.byType(DeliverableAttachment), findsNWidgets(3));
    for (final action in find.byTooltip('Open preview').evaluate().toList()) {
      final target = find.byElementPredicate(
        (element) => identical(element, action),
      );
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pumpAndSettle();
    }
    expect(opened, ['/srv/report.md', '/srv/report.md', '/srv/report.md']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'pending download prevents duplicate requests and cancellation is quiet',
    (tester) async {
      final pending = Completer<bool>();
      final previewPending = Completer<void>();
      var calls = 0;
      await tester.pumpMarkdownWidget(
        message(
          'MEDIA:$reportPath',
          open: (_) => previewPending.future,
          download: (_) {
            calls++;
            return pending.future;
          },
        ),
      );
      expect(find.byIcon(Icons.download_outlined), findsOneWidget);
      final downloadBefore = tester.getRect(find.byTooltip('Download'));
      final previewButton = find.ancestor(
        of: find.byTooltip('Open preview'),
        matching: find.byType(IconButton),
      );
      expect(find.text('Download'), findsNothing);
      expect(find.text('Open preview'), findsNothing);
      expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
      await tester.tap(find.byTooltip('Open preview'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.widget<IconButton>(previewButton).onPressed, isNull);
      previewPending.complete();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Download'));
      await tester.pump();
      expect(find.byIcon(Icons.download_outlined), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.getRect(find.byTooltip('Download')), downloadBefore);
      await tester.tap(find.byTooltip('Download'));
      expect(calls, 1);
      pending.complete(false);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.download_outlined), findsOneWidget);
      expect(find.text('File saved'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed download can retry and no stale completion changes a replaced card',
    (tester) async {
      var calls = 0;
      final pending = Completer<bool>();
      await tester.pumpMarkdownWidget(
        message(
          'MEDIA:$reportPath',
          download: (_) {
            calls++;
            if (calls == 1) {
              throw const DashboardHttpException(403, 'fs/download');
            }
            return pending.future;
          },
        ),
      );
      await tester.tap(find.byTooltip('Download'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Hermes denied access to this file. Ask Hermes for an accessible copy.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Download'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pumpMarkdownWidget(message('MEDIA:/srv/another.md'));
      pending.complete(true);
      await tester.pumpAndSettle();
      expect(find.text('File saved'), findsNothing);
      expect(find.text('another.md'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed preview retains its action and retries with visible progress',
    (tester) async {
      var pending = Completer<void>();
      addTearDown(() {
        if (!pending.isCompleted) pending.complete();
      });
      var calls = 0;
      await tester.pumpMarkdownWidget(
        message(
          'MEDIA:$reportPath',
          open: (_) {
            calls++;
            return pending.future;
          },
        ),
      );
      final action = find.byTooltip('Open preview');
      final before = tester.getRect(action);
      await tester.tap(action);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.getRect(action), before);
      pending.completeError(const DashboardHttpException(403, 'fs/download'));
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('Hermes denied access'), findsOneWidget);
      pending = Completer<void>();
      await tester.tap(action);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.textContaining('Hermes denied access'), findsNothing);
      expect(calls, 2);
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('image download shows progress until completion', (tester) async {
    final pending = Completer<bool>();
    addTearDown(() {
      if (!pending.isCompleted) pending.complete(false);
    });
    var calls = 0;
    await tester.pumpMarkdownWidget(
      message(
        'MEDIA:/srv/image.png',
        download: (output) {
          expect(output.path, '/srv/image.png');
          calls++;
          return pending.future;
        },
      ),
    );
    await tester.tap(find.byTooltip('Download image'));
    await tester.pump();
    final action = find.byTooltip('Saving image');
    expect(
      find.descendant(
        of: action,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    await tester.tap(action);
    expect(calls, 1);
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Download image'), findsOneWidget);
    expect(find.byTooltip('Saving image'), findsNothing);
    expect(find.text('File saved'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('deliverable at 320dp $brightness $scale text', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final boundary = GlobalKey();
        var pending = Completer<void>();
        addTearDown(() {
          if (!pending.isCompleted) pending.complete();
        });
        var openCalls = 0;
        var downloadCalls = 0;
        await tester.pumpMarkdownWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: scale == 2,
              ),
              child: child!,
            ),
            home: RepaintBoundary(
              key: boundary,
              child: Scaffold(
                appBar: AppBar(title: const Text('Memory review')),
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: ProfileMessage(
                    message: TranscriptMessage.fromRow(const {
                      'role': 'assistant',
                      'content':
                          'The visual report is ready:\n\n$htmlReportPath\n\nOpen it to explore the charts and tables.',
                    }),
                    onOpenRemoteFile: (_) async {
                      openCalls++;
                      await pending.future;
                    },
                    onDownloadRemoteFile: (_) async {
                      downloadCalls++;
                      await pending.future;
                      return false;
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final action in ['Download', 'Open preview']) {
          final button = find.byTooltip(action);
          expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
          expect(tester.getSize(button).width, greaterThanOrEqualTo(48));
          expect(find.text(action), findsNothing);
          expect(button.hitTestable(), findsOneWidget);
        }
        await tester.tap(find.byTooltip('Download'));
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        await tester.tap(find.byTooltip('Download'));
        expect(downloadCalls, 1);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(milliseconds: 250));
        if (const bool.fromEnvironment('CAPTURE_DELIVERABLES')) {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File(
              'build/deliverables-review/${brightness.name}-$scale.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
        pending.complete();
        await tester.pumpAndSettle();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        pending = Completer<void>();
        await tester.tap(find.byTooltip('Open preview'));
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        await tester.tap(find.byTooltip('Open preview'));
        expect(openCalls, 1);
        await tester.pumpWidget(const SizedBox());
        pending.complete();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
