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
import 'package:wing/core/widgets/profile_message.dart';

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
        message: {'role': 'assistant', 'content': text},
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
      await tester.pumpWidget(
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
      await tester.tap(find.text('Open preview'));
      await tester.pumpAndSettle();
      expect(opened, reportPath);
      expect(downloaded, isNull);
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(downloaded, reportPath);
      expect(find.text('File saved'), findsOneWidget);
      await tester.tap(find.byTooltip('Copy message'));
      await tester.pump();
      expect(copied, source);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('screenshot report paths open independently and copy verbatim', (
    tester,
  ) async {
    const report =
        '/home/tarkil/projects/memory-maintenance/reports/monthly-pilot-20260927/report.md';
    const questions =
        '/home/tarkil/projects/memory-maintenance/evaluation/private/monthly-pilot-20260927-151620/case-review.md';
    const source =
        '**Report**\n\nThe dashboard is here:\n\n`$report`\n\n'
        'The private question sheet is here:\n\n`$questions`';
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
    await tester.pumpWidget(
      message(source, open: (output) async => opened.add(output.path!)),
    );
    expect(find.byType(DeliverableAttachment), findsNWidgets(2));
    expect(find.text('report.md'), findsOneWidget);
    expect(find.text('case-review.md'), findsOneWidget);
    for (var index = 0; index < 2; index++) {
      final action = find.text('Open preview').at(index);
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
    '`$htmlReportPath`': htmlReportPath,
    '[HTML report]($htmlReportPath)': htmlReportPath,
    'MEDIA:$htmlReportPath': htmlReportPath,
    '`$reportPath`': reportPath,
    '`` /srv/My report.md ``': '/srv/My report.md',
    '`/srv/report%23final.md`': '/srv/report%23final.md',
    '`/srv/report#final?.md`': '/srv/report#final?.md',
    '`~/reports/report.md`': '~/reports/report.md',
    '`../reports/report.md`': '../reports/report.md',
    r'`C:\Users\a\report.md`': r'C:\Users\a\report.md',
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
      await tester.pumpWidget(
        message(entry.key, open: (output) async => path = output.path),
      );
      await tester.tap(find.text('Open preview'));
      await tester.pumpAndSettle();
      expect(path, entry.value);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('plain HTML paths do not capture URLs, code or other filenames', (
    tester,
  ) async {
    await tester.pumpWidget(
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
      await tester.pumpWidget(
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
      expect(find.text('Image'), findsOneWidget);
      expect(find.textContaining('MEDIA:/srv/example.md'), findsOneWidget);
      expect(find.textContaining('MEDIA:unsupported:value'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('repeated file references and table links remain usable', (
    tester,
  ) async {
    await tester.pumpWidget(
      message(
        '[First](/srv/report.md) and [Again](/srv/report.md)\n\n'
        '| Report |\n| --- |\n| [Read](/srv/report.md) |',
        open: (_) async {},
      ),
    );
    expect(find.byType(DeliverableAttachment), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'pending download prevents duplicate requests and cancellation is quiet',
    (tester) async {
      final pending = Completer<bool>();
      final previewPending = Completer<void>();
      var calls = 0;
      await tester.pumpWidget(
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
      final captionBefore = tester.getRect(find.text('Download'));
      final previewButton = find.widgetWithText(OutlinedButton, 'Open preview');
      expect(
        tester.getCenter(find.text('Open preview')).dx,
        tester.getCenter(previewButton).dx,
      );
      await tester.tap(find.text('Open preview'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        find.descendant(of: previewButton, matching: find.byType(Icon)),
        findsNothing,
      );
      previewPending.complete();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download'));
      await tester.pump();
      expect(find.byIcon(Icons.download_outlined), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.getRect(find.text('Download')), captionBefore);
      await tester.tap(find.text('Download'));
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
      await tester.pumpWidget(
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
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Hermes denied access to this file. Ask Hermes for an accessible copy.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Download'));
      await tester.pump();
      await tester.pumpWidget(message('MEDIA:/srv/another.md'));
      pending.complete(true);
      await tester.pumpAndSettle();
      expect(find.text('File saved'), findsNothing);
      expect(find.text('another.md'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('deliverable at 320dp $brightness $scale text', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final boundary = GlobalKey();
        await tester.pumpWidget(
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
                appBar: AppBar(title: const Text('Memory review')),
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: ProfileMessage(
                    message: const {
                      'role': 'assistant',
                      'content':
                          'The visual report is ready:\n\n$htmlReportPath\n\nOpen it to explore the charts and tables.',
                    },
                    onOpenRemoteFile: (_) async {},
                    onDownloadRemoteFile: (_) async => true,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final action in ['Download', 'Open preview']) {
          final button = find.ancestor(
            of: find.text(action),
            matching: find.byType(OutlinedButton),
          );
          expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
          expect(tester.getRect(button).right, lessThanOrEqualTo(304));
        }
        expect(tester.takeException(), isNull);
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
      });
    }
  }
}
