import 'package:wing/core/services/chat_outputs_session.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/chat_output.dart';
import 'package:wing/core/screens/chat_outputs_screen.dart';
import 'package:wing/core/screens/html_preview_screen.dart';
import 'package:wing/core/services/remote_files_client.dart';
import 'package:wing/core/widgets/web_output_preview.dart';

void main() {
  testWidgets(
    'large HTML reports open in the native viewer without a 1 MiB barrier',
    (tester) async {
      final source =
          '<!doctype html><!--${'x' * (2 * 1024 * 1024)}--><h1>Complete large report</h1>';
      Map<Object?, Object?>? creation;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        (call) async {
          if (call.method == 'create') {
            final args = call.arguments as Map;
            creation =
                const StandardMessageCodec().decodeMessage(
                      ByteData.sublistView(args['params'] as Uint8List),
                    )
                    as Map<Object?, Object?>;
            return 1;
          }
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
        MaterialApp(
          home: HtmlPreviewScreen(
            title: 'index.html',
            download: () async => RemoteFileDownload(
              filename: 'index.html',
              bytes: utf8.encode(source),
            ),
            share: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AndroidView), findsOneWidget);
      expect(creation?['source'], source);
      expect(creation?['format'], 'html');
      expect(find.textContaining('1 MiB'), findsNothing);
    },
  );

  testWidgets('chat HTML opens full viewer and Back returns directly to chat', (
    tester,
  ) async {
    const path = '/srv/reports/index.html';
    const source = '<!doctype html><h1>Full report</h1>';
    final downloads = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ChatOutputsScreen(
                    chatTitle: 'Report chat',
                    initialOutput: const ChatOutput(
                      kind: ChatOutputKind.file,
                      path: path,
                      url: null,
                      label: 'index.html',
                    ),
                    createSession: () => ChatOutputsSession(
                      loadHistory: (_) => throw StateError('Unneeded history'),
                      readText: (_) => throw StateError(
                        'HTML must bypass the text-preview limit',
                      ),
                      download: (path) async {
                        downloads.add(path);
                        return RemoteFileDownload(
                          filename: 'index.html',
                          bytes: utf8.encode(source),
                        );
                      },
                    ),
                  ),
                ),
              ),
              child: const Text('Open preview'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open preview'));
    await tester.pumpAndSettle();
    expect(downloads, [path]);
    final viewer = tester.widget<WebOutputPreview>(
      find.byType(WebOutputPreview),
    );
    expect(viewer.source, source);
    expect(viewer.format, WebOutputFormat.html);
    expect(find.textContaining('Preview shortened'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Open preview'), findsOneWidget);
    expect(find.byType(ChatOutputsScreen), findsNothing);
  });

  testWidgets('download failure offers retry and renders the retried file', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        home: HtmlPreviewScreen(
          title: 'index.html',
          download: () async {
            if (++calls == 1) throw TimeoutException('test');
            return RemoteFileDownload(
              filename: 'index.html',
              bytes: utf8.encode('<h1>Report</h1>'),
            );
          },
          share: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('could not be reached'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byType(WebOutputPreview), findsOneWidget);
  });

  testWidgets(
    'invalid UTF-8 offers original file without rendering partial HTML',
    (tester) async {
      final file = RemoteFileDownload(filename: 'index.html', bytes: [0xff]);
      RemoteFileDownload? shared;
      var downloads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: HtmlPreviewScreen(
            title: 'index.html',
            download: () async {
              downloads++;
              return file;
            },
            share: (file) async => shared = file,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining("can't be read here"), findsOneWidget);
      expect(find.byType(WebOutputPreview), findsNothing);
      await tester.tap(find.byTooltip('Save or share'));
      await tester.pumpAndSettle();
      expect(shared, same(file));
      expect(downloads, 1);
    },
  );
}
