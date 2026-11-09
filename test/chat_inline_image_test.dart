import 'package:wing/core/models/transcript_message.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:wing/core/models/chat_output.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/chat_image_preview.dart';
import 'package:wing/core/widgets/chat_inline_image.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';

import 'helpers/pump_markdown_widget.dart';

Finder inlineImage() => find.descendant(
  of: find.byType(ChatInlineImage),
  matching: find.byType(Image),
);

Future<void> settleImages(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  for (final element in find.byType(Image).evaluate()) {
    final image = element.widget as Image;
    await tester.runAsync(
      () => precacheImage(image.image, element, onError: (_, _) {}),
    );
  }
  await tester.pumpAndSettle();
}

void main() {
  final pixels = img.Image(width: 600, height: 900);
  img.fill(pixels, color: img.ColorRgb8(33, 80, 73));
  img.fillCircle(
    pixels,
    x: 210,
    y: 340,
    radius: 130,
    color: img.ColorRgb8(235, 174, 182),
  );
  img.fillCircle(
    pixels,
    x: 385,
    y: 300,
    radius: 120,
    color: img.ColorRgb8(245, 221, 158),
  );
  final bytes = Uint8List.fromList(img.encodePng(pixels));

  setUpAll(() async {
    if (!const bool.fromEnvironment('CAPTURE_INLINE_IMAGES')) return;
    for (final entry in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(
              '/tmp/approval-fonts/${entry.value}',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });

  Widget message(
    String content, {
    Future<Uint8List> Function(String)? load,
    Future<void> Function(ChatOutput)? open,
    Future<bool> Function(ChatOutput)? download,
  }) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: ProfileMessage(
          message: TranscriptMessage.fromRow({
            'role': 'assistant',
            'content': content,
          }),
          loadAttachmentImage: load,
          onOpenRemoteFile: open,
          onDownloadRemoteFile: download,
        ),
      ),
    ),
  );

  for (final source in [
    'MEDIA:/srv/bouquet.jpg',
    '[Bouquet](/srv/bouquet.jpg)',
    '![Bouquet](/srv/bouquet.jpg)',
    '| Flowers |\n| --- |\n| [Bouquet](/srv/bouquet.jpg) |',
  ]) {
    testWidgets('remote image renders inline: $source', (tester) async {
      final requests = <String>[];
      await tester.pumpMarkdownWidget(
        message(
          source,
          load: (path) async {
            requests.add(path);
            return bytes;
          },
        ),
      );
      await settleImages(tester);
      expect(requests, ['/srv/bouquet.jpg']);
      expect(find.byType(ChatInlineImage), findsOneWidget);
      expect(inlineImage(), findsOneWidget);
      expect(find.text('This image could not be previewed.'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('inline-code image paths remain literal text', (tester) async {
    final requests = <String>[];
    await tester.pumpMarkdownWidget(
      message(
        '`/srv/bouquet.jpg`',
        load: (path) async {
          requests.add(path);
          return bytes;
        },
      ),
    );
    await settleImages(tester);
    expect(requests, isEmpty);
    expect(find.byType(ChatInlineImage), findsNothing);
    expect(find.text('/srv/bouquet.jpg', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('image actions retain exact paths and copy source', (
    tester,
  ) async {
    const source = 'Warm pastels.\n\nMEDIA:/srv/bouquet.jpg\n\nSmall size.';
    String? copied;
    String? downloaded;
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
        load: (_) async => bytes,
        download: (output) async {
          downloaded = output.path;
          return false;
        },
      ),
    );
    await settleImages(tester);
    await tester.tap(inlineImage());
    await settleImages(tester);
    expect(
      tester.widget<ChatImagePreview>(find.byType(ChatImagePreview)).bytes,
      orderedEquals(bytes),
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Download image'));
    await tester.pump();
    expect(downloaded, '/srv/bouquet.jpg');
    await tester.tap(find.byTooltip('Copy message'));
    expect(copied, source);
  });

  testWidgets('viewer uses original bytes and rebuilds do not reload', (
    tester,
  ) async {
    var loads = 0;
    Future<Uint8List> load(String _) async {
      loads++;
      return bytes;
    }

    await tester.pumpMarkdownWidget(
      message('![Bouquet](/srv/bouquet.jpg)', load: load),
    );
    await settleImages(tester);
    await tester.pumpMarkdownWidget(
      message('![Bouquet](/srv/bouquet.jpg)', load: load),
    );
    expect(loads, 1);
    await tester.tap(inlineImage());
    await settleImages(tester);
    final preview = tester.widget<ChatImagePreview>(
      find.byType(ChatImagePreview),
    );
    expect(preview.bytes, orderedEquals(bytes));
  });

  testWidgets('failed read retries; stale result cannot replace a new target', (
    tester,
  ) async {
    final pending = Completer<Uint8List>();
    var calls = 0;
    Future<Uint8List> load(String path) {
      if (path == '/srv/second.jpg') return Future.value(bytes);
      calls++;
      if (calls == 1) return Future.error(StateError('failed read'));
      return pending.future;
    }

    await tester.pumpMarkdownWidget(
      message('MEDIA:/srv/first.jpg', load: load),
    );
    await tester.pumpAndSettle();
    expect(find.text('This image could not be previewed.'), findsOneWidget);
    await tester.tap(find.byTooltip('Retry image'));
    await tester.pump();
    expect(calls, 2);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpMarkdownWidget(
      message('MEDIA:/srv/second.jpg', load: load),
    );
    pending.completeError(StateError('stale failure'));
    await settleImages(tester);
    expect(find.text('This image could not be previewed.'), findsNothing);
    expect(
      tester.widget<ChatInlineImage>(find.byType(ChatInlineImage)).target,
      '/srv/second.jpg',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('corrupt image can be retried with fresh bytes', (tester) async {
    var calls = 0;
    await tester.pumpMarkdownWidget(
      message(
        'MEDIA:/srv/bouquet.jpg',
        load: (_) async => ++calls == 1 ? Uint8List.fromList([1, 2]) : bytes,
      ),
    );
    await settleImages(tester);
    expect(find.byTooltip('Retry image'), findsOneWidget);
    await tester.tap(find.byTooltip('Retry image'));
    await settleImages(tester);
    expect(calls, 2);
    expect(find.byTooltip('Retry image'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('document images resolve against their document directory', (
    tester,
  ) async {
    String? requested;
    await tester.pumpMarkdownWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownMessageContent(
            data: '![Bouquet](../images/bouquet.jpg)',
            documentPath: '/srv/reports/flowers.md',
            loadImage: (path) async {
              requested = path;
              return bytes;
            },
          ),
        ),
      ),
    );
    await settleImages(tester);
    expect(requested, '/srv/images/bouquet.jpg');
    expect(inlineImage(), findsOneWidget);
  });

  testWidgets('web images never use the authenticated Hermes loader', (
    tester,
  ) async {
    var loads = 0;
    await tester.pumpMarkdownWidget(
      message(
        '![Bouquet](https://example.com/bouquet.jpg)',
        load: (_) async {
          loads++;
          return bytes;
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(loads, 0);
    final provider = tester.widget<Image>(inlineImage()).image as ResizeImage;
    final network = provider.imageProvider as NetworkImage;
    expect(network.url, 'https://example.com/bouquet.jpg');
    expect(network.headers, isNull);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'failed image keeps actions reachable at enlarged text: $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpMarkdownWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: ProfileMessage(
                  message: TranscriptMessage.fromRow(const {
                    'role': 'assistant',
                    'content': 'MEDIA:/srv/bouquet.jpg',
                  }),
                  loadAttachmentImage: (_) async =>
                      throw StateError('unavailable'),
                  onDownloadRemoteFile: (_) async => false,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final retry = tester.getRect(find.byTooltip('Retry image'));
        final download = tester.getRect(find.byTooltip('Download image'));
        expect(retry.overlaps(download), isFalse);
        expect(download.height, greaterThanOrEqualTo(48));
        expect(find.byTooltip('Retry image').hitTestable(), findsOneWidget);
        expect(find.byTooltip('Download image').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('inline image at phone size: $brightness $scale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final boundary = GlobalKey();
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
                appBar: AppBar(title: const Text('Flower delivery')),
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: ProfileMessage(
                    message: TranscriptMessage.fromRow(const {
                      'role': 'assistant',
                      'content':
                          '**Windflower · S\$66**\n\n'
                          'A mixed bouquet in warm pastels.\n\n'
                          'MEDIA:/srv/daily-surprise-bouquet.jpg',
                    }),
                    loadAttachmentImage: (_) async => bytes,
                    onOpenRemoteFile: (_) async {},
                    onDownloadRemoteFile: (_) async => false,
                  ),
                ),
              ),
            ),
          ),
        );
        await settleImages(tester);
        final image = tester.widget<Image>(inlineImage());
        expect(image.fit, BoxFit.scaleDown);
        expect(tester.getSize(inlineImage()).height, lessThanOrEqualTo(320));
        expect(inlineImage().hitTestable(), findsOneWidget);
        for (final text in ['Download image']) {
          final button = find.byTooltip(text);
          await tester.ensureVisible(button);
          expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
          expect(button.hitTestable(), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        if (const bool.fromEnvironment('CAPTURE_INLINE_IMAGES')) {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File(
              'build/inline-images/${brightness.name}-$scale.png',
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
