import 'package:wing/core/models/transcript_message.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:wing/core/models/answer_versions.dart';
import 'package:wing/core/models/user_message_content.dart';
import 'package:wing/core/models/reading_snapshot_message.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/chat_image_preview.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'package:wing/core/widgets/studio_error.dart';
import 'package:wing/core/widgets/user_message_attachment.dart';

Future<void> settleImages(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  for (final element in find.byType(Image).evaluate()) {
    final image = element.widget as Image;
    await tester.runAsync(
      () => precacheImage(image.image, element, onError: (_, _) {}),
    );
  }
  // A provider may resolve during the preceding decode and only insert its
  // full-size Image on the next frame. Allow that codec to deliver its frame
  // before settling animations, including the viewer's loading indicator.
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {
  final captureSamples = <Uint8List>[];
  test('reading projection owns an immutable attachment snapshot', () {
    final attachments = <UserMessageAttachment>[
      const UserMessageAttachment(
        name: 'First.txt',
        target: '/first.txt',
        isImage: false,
      ),
    ];
    final row = <String, dynamic>{
      'id': 7,
      'role': 'user',
      'content': '@file:/first.txt\nKeep caption',
      'timestamp': 100,
      'submitted_attachments': attachments,
    };
    final message = TranscriptMessage.fromRow(row);
    final savedTime = message.timestamp;
    attachments.clear();
    row.addAll({
      'id': 8,
      'role': 'assistant',
      'content': 'Replacement',
      'timestamp': 200,
    });

    expect(message.id, 7);
    expect(message.role, 'user');
    expect(message.text, 'Keep caption');
    expect(message.copyText, '@file:/first.txt\nKeep caption');
    expect(message.timestamp, savedTime);
    expect(message.attachments.single.name, 'First.txt');
    expect(message.attachments.single.target, '/first.txt');
    expect(() => message.attachments.clear(), throwsUnsupportedError);
  });

  test('reading projection owns immutable tool facts', () {
    final toolRow = <String, dynamic>{
      'id': 3,
      'role': 'tool',
      'tool_name': 'read',
      'content': 'Original output',
    };
    final tool = TranscriptMessage.fromRow(toolRow).tool!;
    toolRow.addAll({
      'id': 4,
      'tool_name': 'write',
      'content': 'Replacement output',
    });
    expect(tool.id, 3);
    expect(tool.name, 'read');
    expect(tool.text, 'Original output');
  });

  setUpAll(() async {
    if (!const bool.fromEnvironment('CAPTURE_ATTACHMENTS')) return;
    const directory = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(entry.key)
        ..addFont(
          File(
            '$directory/${entry.value}',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await loader.load();
    }
    for (final name in [
      'conversation-dark',
      'analytics-dark',
      'appearance-dark',
      'administration-dark',
      'chats-dark',
      'welcome-light',
    ]) {
      captureSamples.add(
        await File('docs/screenshots/$name.png').readAsBytes(),
      );
    }
  });
  final pixels = img.Image(width: 180, height: 280);
  img.fill(pixels, color: img.ColorRgb8(20, 100, 105));
  img.fillRect(
    pixels,
    x1: 20,
    y1: 24,
    x2: 160,
    y2: 170,
    color: img.ColorRgb8(170, 220, 210),
  );
  final bytes = Uint8List.fromList(img.encodePng(pixels));
  final dataUrl = 'data:image/png;base64,${base64Encode(bytes)}';
  Map<String, dynamic> saved({String? image, String text = 'Look at this.'}) =>
      {
        'id': 42,
        'role': 'user',
        'content': [
          {'type': 'text', 'text': text},
          {
            'type': 'image_url',
            'image_url': {'url': image ?? dataUrl},
          },
        ],
      };

  test(
    'saved and branch history retain image parts without exposing bytes',
    () {
      for (final message in [
        saved(),
        answerHistoryRows([saved()]).single,
      ]) {
        final content = UserMessageContent.fromMessage(message);
        expect(content.text, 'Look at this.');
        expect(content.attachments.single.target, dataUrl);
        expect(content.attachments.single.isImage, isTrue);
        expect(answerMessageDisplayText(message), 'Look at this.\n[image]');
      }
    },
  );

  test('display captions preserve saved image attachments', () {
    final overridden = UserMessageContent.fromMessage({
      ...saved(),
      'display_content': 'A visible caption',
    });
    expect(overridden.text, 'A visible caption');
    expect(overridden.attachments, hasLength(1));
  });

  test('file cards use standalone references and remove expanded context', () {
    final content = UserMessageContent.fromMessage({
      'role': 'user',
      'content':
          '@file:"/server/report final.PDF"\n\nSummarize.\n\n'
          '--- Attached Context ---\n📄 @file:"/server/report final.PDF"\nSecret content',
    });
    expect(content.text, 'Summarize.');
    expect(content.attachments.single.name, 'report final.PDF');
    expect(content.attachments.single.extension, 'PDF');
  });

  test('inline file references remain prose', () {
    final prose = UserMessageContent.fromMessage({
      'role': 'user',
      'content': 'Explain @file:report.pdf and [image]',
    });
    expect(prose.text, 'Explain @file:report.pdf and [image]');
    expect(prose.attachments, isEmpty);
  });

  test('stock screenshot placeholders do not repeat attached images', () {
    const raw =
        'Compare these.\n@image:/server/one.png\n@image:/server/two.png\n[screenshot]\n[screenshot]';
    final message = TranscriptMessage.fromRow({
      'id': 42,
      'role': 'user',
      'content': raw,
    });
    expect(message.text, 'Compare these.');
    expect(message.attachments, hasLength(2));
    expect(message.copyText, raw);
    for (final raw in [
      'Explain [screenshot]',
      'Explain\n[screenshot]',
      '@image:/server/one.png\n[screenshot]\n[screenshot]',
    ]) {
      expect(
        UserMessageContent.fromMessage({'content': raw}).text,
        contains('[screenshot]'),
      );
    }
  });

  final nativePaths = List.generate(
    5,
    (index) => '/server/images/upload_${index + 6}.png',
  );
  final nativeCaption = 'Regarde les images, et prépare un assortiment.';
  final nativeRaw = [
    nativeCaption,
    '',
    ...nativePaths.map((path) => '[Image attached at: $path]'),
    ...List.filled(5, '[screenshot]'),
    '<memory-context>Private model context</memory-context>',
  ].join('\n');
  final nativeRow = <String, dynamic>{
    'id': 42,
    'role': 'user',
    'content': nativeRaw,
  };

  test(
    'native vision saved image markers survive history and reading cache',
    () {
      for (final row in [
        nativeRow,
        answerHistoryRows([nativeRow]).single,
        projectReadingSnapshotMessage(nativeRow),
      ]) {
        final message = TranscriptMessage.fromRow(row);
        expect(message.text, nativeCaption);
        expect(message.attachments.map((file) => file.target), nativePaths);
        expect(message.attachments.every((file) => file.isImage), isTrue);
        expect(message.copyText, nativeRaw);
      }
    },
  );

  test('native vision markers retain spaces and CRLF server paths', () {
    const raw =
        'Compare these.\r\n\r\n'
        '[Image attached at: /server/first image.png]\r\n'
        '[Image attached at: /server/second image.png]\r\n'
        '[screenshot]\r\n[screenshot]\r\n';
    final message = TranscriptMessage.fromRow({'role': 'user', 'content': raw});
    expect(message.text, 'Compare these.');
    expect(message.attachments.map((file) => file.target), [
      '/server/first image.png',
      '/server/second image.png',
    ]);
    expect(message.copyText, raw.trim());
  });

  test('native vision image parts and hints describe the same attachments', () {
    final message = TranscriptMessage.fromRow({
      'role': 'user',
      'content': [
        {
          'type': 'text',
          'text':
              'Compare these.\n\n'
              '[Image attached at: /server/one.png]\n'
              '[Image attached at: /server/two.png]',
        },
        {
          'type': 'image_url',
          'image_url': {'url': 'data:image/png;base64,AQ=='},
        },
        {
          'type': 'image_url',
          'image_url': {'url': 'data:image/png;base64,Ag=='},
        },
        {'type': 'text', 'text': '\n<memory-context>Context</memory-context>'},
      ],
    });
    expect(message.text, 'Compare these.');
    expect(message.attachments.map((file) => file.target), [
      '/server/one.png',
      '/server/two.png',
    ]);
  });

  test('literal and incomplete native vision markers remain prose', () {
    for (final raw in [
      'Explain [Image attached at: /server/one.png]',
      'Example:\n\n[Image attached at: /server/one.png]',
      'Example:\n\n```\n[Image attached at: /server/one.png]\n[screenshot]\n```',
      'Example:\n\n> [Image attached at: /server/one.png]\n[screenshot]',
      'Compare.\n\n[Image attached at: ]\n[screenshot]',
      'Compare.\n\n[Image attached at: /server/one.png]\n[screenshot]\n[screenshot]',
      'Compare.\n\n[Image attached at: /server/one.png]\n[screenshot]\n'
          '<memory-context>Incomplete context',
      'Compare.\n\n[Image attached at: /server/one.png]\n[screenshot]\nMore prose.',
    ]) {
      final content = UserMessageContent.fromMessage({
        'role': 'user',
        'content': raw,
      });
      expect(content.text, raw);
      expect(content.attachments, isEmpty);
    }
  });

  testWidgets('native vision saved images display and open each original', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final requests = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ProfileMessage(
              message: TranscriptMessage.fromRow(nativeRow),
              loadAttachmentImage: (path) async {
                requests.add(path);
                return bytes;
              },
            ),
          ),
        ),
      ),
    );
    await settleImages(tester);
    expect(find.byType(UserMessageAttachmentTile), findsNWidgets(5));
    expect(find.byType(Image), findsNWidgets(5));
    expect(requests, nativePaths);
    expect(find.textContaining('[Image attached at:'), findsNothing);
    expect(find.textContaining('[screenshot]'), findsNothing);
    expect(find.textContaining('Private model context'), findsNothing);
    for (var index = 0; index < nativePaths.length; index++) {
      await tester.tap(find.byType(UserMessageAttachmentTile).at(index));
      await settleImages(tester);
      final viewer = tester.widget<ChatImageViewport>(
        find.byType(ChatImageViewport),
      );
      expect(viewer.title, 'upload_${index + 6}.png');
      expect(viewer.bytes, orderedEquals(bytes));
      await tester.pageBack();
      await settleImages(tester);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('image-only message is visible and opens a zoomable preview', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileMessage(
            message: TranscriptMessage.fromRow(saved(text: '')),
          ),
        ),
      ),
    );
    await settleImages(tester);
    expect(find.byType(UserMessageAttachmentTile), findsOneWidget);
    expect(find.text('[image]'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    await tester.tap(find.byType(Image));
    await settleImages(tester);
    expect(find.byType(ChatImageViewport), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.pageBack();
    await settleImages(tester);
    expect(find.byType(ChatImageViewport), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'long screenshots show a capped top crop and open the complete image',
    (tester) async {
      final screenshot = img.Image(width: 180, height: 2800);
      img.fill(screenshot, color: img.ColorRgb8(20, 40, 80));
      img.fillRect(
        screenshot,
        x1: 0,
        y1: 0,
        x2: 179,
        y2: 599,
        color: img.ColorRgb8(170, 220, 210),
      );
      final original = Uint8List.fromList(img.encodePng(screenshot));
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: RepaintBoundary(
                key: boundary,
                child: UserMessageAttachmentTile(
                  attachment: const UserMessageAttachment(
                    name: 'Scrolling screenshot.png',
                    target: '/screenshot.png',
                    isImage: true,
                  ),
                  loadImage: (_) async => original,
                ),
              ),
            ),
          ),
        ),
      );
      await settleImages(tester);
      final thumbnail = tester.getSize(find.byType(Image));
      expect(
        thumbnail.height,
        lessThan(thumbnail.width * screenshot.height / screenshot.width),
      );
      expect(
        thumbnail.height,
        lessThan(
          tester.view.physicalSize.height / tester.view.devicePixelRatio,
        ),
      );
      // Both ends of the rendered thumbnail show the top section. Fitting the
      // entire screenshot would instead expose the navy bottom and side bars.
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage();
        final pixels = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        for (final point in [
          Offset(image.width * .1, image.height * .1),
          Offset(image.width * .9, image.height * .9),
        ]) {
          final offset =
              (point.dy.toInt() * image.width + point.dx.toInt()) * 4;
          expect(pixels.buffer.asUint8List(offset, 4), [170, 220, 210, 255]);
        }
        image.dispose();
      });
      await tester.tap(find.byType(Image));
      await settleImages(tester);
      expect(
        tester.widget<ChatImageViewport>(find.byType(ChatImageViewport)).bytes,
        orderedEquals(original),
      );
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'server image uses its loader, retries failure and survives rebuilds',
    (tester) async {
      var requests = 0;
      Future<Uint8List> load(String path) async {
        expect(path, '/server/photo.png');
        requests++;
        if (requests == 1) throw StateError('Offline');
        return bytes;
      }

      Widget app() => MaterialApp(
        home: Scaffold(
          body: ProfileMessage(
            message: TranscriptMessage.fromRow(
              saved(image: '/server/photo.png'),
            ),
            loadAttachmentImage: load,
          ),
        ),
      );
      await tester.pumpWidget(app());
      await settleImages(tester);
      expect(find.text('Can’t load image'), findsOneWidget);
      await tester.tap(find.byTooltip('Retry image preview'));
      await settleImages(tester);
      expect(find.byType(Image), findsOneWidget);
      await tester.pumpWidget(app());
      await settleImages(tester);
      expect(requests, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('malformed image data retains the original viewer action', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileMessage(
            message: TranscriptMessage.fromRow(
              saved(image: 'data:image/png;base64,bm90IGFuIGltYWdl'),
            ),
          ),
        ),
      ),
    );
    await settleImages(tester);
    expect(find.text('Can’t load image'), findsOneWidget);
    await tester.tap(find.byTooltip('Open original image'));
    await settleImages(tester);
    expect(find.byType(ChatImageViewport), findsOneWidget);
    expect(find.text('This image could not be previewed.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed server previews recover after returning to the app', (
    tester,
  ) async {
    var online = false;
    var requests = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileMessage(
            message: TranscriptMessage.fromRow(
              saved(image: '/server/photo.png'),
            ),
            loadAttachmentImage: (_) async {
              requests++;
              if (!online) throw StateError('Offline');
              return bytes;
            },
          ),
        ),
      ),
    );
    await settleImages(tester);
    expect(find.text('Can’t load image'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    online = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settleImages(tester);
    expect(find.text('Can’t load image'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(requests, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settleImages(tester);
    expect(requests, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'confirmed reconnection repairs failure without reloading success',
    (tester) async {
      var requests = 0;
      Widget app({required bool online}) => MaterialApp(
        home: Scaffold(
          body: ProfileMessage(
            message: TranscriptMessage.fromRow(
              saved(image: '/server/photo.png'),
            ),
            attachmentImagesAvailable: online,
            loadAttachmentImage: (_) async {
              requests++;
              if (!online) throw StateError('Offline');
              return bytes;
            },
          ),
        ),
      );
      await tester.pumpWidget(app(online: false));
      await settleImages(tester);
      expect(find.text('Can’t load image'), findsOneWidget);
      await tester.pumpWidget(app(online: true));
      await settleImages(tester);
      expect(find.text('Can’t load image'), findsNothing);
      expect(find.byType(Image), findsOneWidget);
      await tester.pumpWidget(app(online: false));
      await settleImages(tester);
      await tester.pumpWidget(app(online: true));
      await settleImages(tester);
      expect(requests, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'image grid keeps loading and failed previews compact and retryable',
    (tester) async {
      final pending = Completer<Uint8List>();
      var online = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProfileMessage(
              message: TranscriptMessage.fromRow({
                'id': 42,
                'role': 'user',
                'content':
                    '@image:/server/ready.png\n@image:/server/failed.png\n@image:/server/pending.png',
              }),
              loadAttachmentImage: (path) async {
                if (path.endsWith('pending.png')) {
                  return pending.future;
                }
                if (path.endsWith('failed.png') && !online) {
                  throw StateError('Offline');
                }
                return bytes;
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Can’t load image'), findsOneWidget);
      expect(find.byType(StudioErrorFrame), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      final tiles = find.byType(UserMessageAttachmentTile);
      final first = tester.getRect(tiles.at(0));
      final failed = tester.getRect(tiles.at(1));
      final loading = tester.getRect(tiles.at(2));
      expect(first.size, failed.size);
      expect(loading.height, first.height);
      final retry = find.byTooltip('Retry image preview');
      expect(tester.getSize(retry).shortestSide, greaterThanOrEqualTo(48));
      online = true;
      await tester.tap(retry);
      pending.complete(bytes);
      await settleImages(tester);
      expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
      expect(find.byType(Image), findsNWidgets(3));
      expect(tester.getRect(tiles.at(2)), loading);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('returning to the app retires an interrupted preview read', (
    tester,
  ) async {
    final interrupted = Completer<Uint8List>();
    var requests = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileMessage(
            message: TranscriptMessage.fromRow(
              saved(image: '/server/photo.png'),
            ),
            loadAttachmentImage: (_) {
              requests++;
              return requests == 1 ? interrupted.future : Future.value(bytes);
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(requests, 1);
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await settleImages(tester);
    expect(requests, 2);
    expect(find.byType(Image), findsOneWidget);
    interrupted.completeError(StateError('Old connection closed'));
    await settleImages(tester);
    expect(find.text('Can’t load image'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  Future<List<String>> openGallery(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final requests = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ProfileMessage(
              message: TranscriptMessage.fromRow({
                'id': 42,
                'role': 'user',
                'content': List.generate(
                  40,
                  (index) => '@image:/server/$index.png',
                ).join('\n'),
              }),
              loadAttachmentImage: (path) async {
                requests.add(path);
                return bytes;
              },
            ),
          ),
        ),
      ),
    );
    await settleImages(tester);
    expect(requests, List.generate(5, (index) => '/server/$index.png'));
    expect(find.byType(Image), findsNWidgets(5));
    await tester.tapAt(tester.getCenter(find.text('+35')));
    await settleImages(tester);
    return requests;
  }

  testWidgets(
    'gallery arrow navigation preserves the intended image selection',
    (tester) async {
      final requests = await openGallery(tester);
      // Opening reads the visible strip neighborhood, not the whole album.
      expect(requests.toSet().length, lessThan(40));
      for (var index = 0; index < 5; index++) {
        expect(
          requests.where((path) => path == '/server/$index.png'),
          hasLength(1),
        );
      }
      expect(requests, isNot(contains('/server/39.png')));
      final strip = find.byKey(
        const PageStorageKey('user-image-gallery-thumbnails'),
      );
      expect(
        find.descendant(of: strip, matching: find.byType(Text)),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('image-thumbnail-4')), findsOneWidget);
      for (var index = 4; index < 40; index++) {
        final preview = tester.widget<ChatImageViewport>(
          find.byType(ChatImageViewport),
        );
        expect(preview.title, '$index.png');
        expect(preview.bytes, orderedEquals(bytes));
        expect(find.text('${index + 1} / 40'), findsOneWidget);
        expect(find.byType(InteractiveViewer), findsOneWidget);
        if (index < 39) {
          await tester.tap(find.byTooltip('Next image'));
          await settleImages(tester);
        }
      }
      expect(
        tester
            .widget<IconButton>(
              find
                  .ancestor(
                    of: find.byTooltip('Next image'),
                    matching: find.byType(IconButton),
                  )
                  .first,
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byTooltip('Previous image'));
      await settleImages(tester);
      expect(
        tester.widget<ChatImageViewport>(find.byType(ChatImageViewport)).title,
        '38.png',
      );
      await tester.pageBack();
      await settleImages(tester);
      expect(find.byType(Image), findsNWidgets(5));
      expect(find.text('+35'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'gallery swipe navigation preserves the intended image selection',
    (tester) async {
      await openGallery(tester);
      await tester.fling(
        find.byType(InteractiveViewer),
        const Offset(-160, 0),
        600,
      );
      await settleImages(tester);
      expect(find.text('6 / 40'), findsOneWidget);
      await tester.fling(
        find.byType(InteractiveViewer),
        const Offset(160, 0),
        600,
      );
      await settleImages(tester);
      expect(find.text('5 / 40'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('gallery zoomed panning preserves the intended image selection', (
    tester,
  ) async {
    await openGallery(tester);
    final transform = tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!;
    transform.value = Matrix4.diagonal3Values(2, 2, 1);
    await tester.drag(find.byType(InteractiveViewer), const Offset(160, 0));
    await settleImages(tester);
    expect(find.text('5 / 40'), findsOneWidget);
    expect(transform.value.getMaxScaleOnAxis(), 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'gallery two-finger panning preserves the intended image selection',
    (tester) async {
      await openGallery(tester);
      final center = tester.getCenter(find.byType(InteractiveViewer));
      final firstFinger = await tester.startGesture(
        center - const Offset(20, 0),
      );
      final secondFinger = await tester.startGesture(
        center + const Offset(20, 0),
      );
      await firstFinger.moveBy(const Offset(80, 0));
      await secondFinger.moveBy(const Offset(80, 0));
      await firstFinger.up();
      await secondFinger.up();
      await settleImages(tester);
      expect(find.text('5 / 40'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('gallery pinch zoom preserves the intended image selection', (
    tester,
  ) async {
    await openGallery(tester);
    final transform = tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!;
    final center = tester.getCenter(find.byType(InteractiveViewer));
    final pinchLeft = await tester.startGesture(center - const Offset(40, 0));
    final pinchRight = await tester.startGesture(center + const Offset(40, 0));
    await tester.pump();
    await pinchLeft.moveBy(const Offset(-50, 0));
    await pinchRight.moveBy(const Offset(50, 0));
    await tester.pump();
    await pinchLeft.up();
    await pinchRight.up();
    await settleImages(tester);
    expect(transform.value.getMaxScaleOnAxis(), greaterThan(1));
    expect(find.text('5 / 40'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the next original is decoded before a forty-image swipe', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Different byte identities give every original an independent codec key;
    // a cached thumbnail must not masquerade as a prepared full-size image.
    final originals = List.generate(40, (_) => Uint8List.fromList(bytes));
    final requests = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileMessage(
            message: TranscriptMessage.fromRow({
              'role': 'user',
              'content': List.generate(
                40,
                (index) => '@image:/server/$index.png',
              ).join('\n'),
            }),
            loadAttachmentImage: (path) async {
              requests.add(path);
              return originals[int.parse(
                path.split('/').last.split('.').first,
              )];
            },
          ),
        ),
      ),
    );
    await settleImages(tester);
    await tester.tapAt(tester.getCenter(find.text('+35')));
    await settleImages(tester);
    expect(find.text('5 / 40'), findsOneWidget);
    final cache = PaintingBinding.instance.imageCache;
    final nextThumbnail = tester.widget<Image>(
      find.descendant(
        of: find.byKey(const ValueKey('image-thumbnail-5')),
        matching: find.byType(Image),
      ),
    );
    // Acquisition copies into an immutable resource. Inspect that issued
    // original provider, rather than the loader's different byte identity.
    final nextOriginal = (nextThumbnail.image as ResizeImage).imageProvider;
    for (
      var attempt = 0;
      attempt < 20 && !cache.statusForKey(nextOriginal).keepAlive;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(cache.statusForKey(nextOriginal).keepAlive, isTrue);
    expect(cache.statusForKey(nextOriginal).pending, isFalse);
    expect(requests, isNot(contains('/server/39.png')));
    expect(requests.toSet().length, lessThan(40));

    final pages = find.byKey(const ValueKey('user-image-gallery-pages'));
    final finger = await tester.startGesture(tester.getCenter(pages));
    await finger.moveBy(const Offset(-30, 0));
    await tester.pump();
    await finger.moveBy(const Offset(-60, 0));
    await tester.pump(const Duration(milliseconds: 16));
    // Admit the newly mounted page's already-resolved provider; no native
    // decode wait or precache is performed after the drag begins.
    await tester.pump();
    final incoming = find.descendant(
      of: find.byKey(const ValueKey('/server/5.png')),
      matching: find.byType(RawImage),
    );
    expect(incoming, findsOneWidget);
    expect(tester.widget<RawImage>(incoming).image, isNotNull);
    await finger.up();
    await settleImages(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'thumbnail scrolling preserves selection and tapping jumps to image forty',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      try {
        final requests = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ProfileMessage(
                  message: TranscriptMessage.fromRow({
                    'id': 42,
                    'role': 'user',
                    'content': List.generate(
                      40,
                      (index) => '@image:/server/$index.png',
                    ).join('\n'),
                  }),
                  loadAttachmentImage: (path) async {
                    requests.add(path);
                    return bytes;
                  },
                ),
              ),
            ),
          ),
        );
        await settleImages(tester);
        await tester.tapAt(tester.getCenter(find.text('+35')));
        await settleImages(tester);
        final strip = find.byKey(
          const PageStorageKey('user-image-gallery-thumbnails'),
        );
        final controller = tester.widget<ListView>(strip).controller!;
        controller.jumpTo(controller.position.maxScrollExtent);
        await settleImages(tester);
        expect(find.text('5 / 40'), findsOneWidget);
        // The rail can be far from the selected image. Arrow navigation brings
        // it back without acquiring every original swept by a long animation.
        await tester.tap(find.byTooltip('Next image'));
        await tester.pump();
        for (var frame = 0; frame < 26; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        await settleImages(tester);
        expect(find.text('6 / 40'), findsOneWidget);
        expect(
          requests.where((path) {
            final index = int.parse(path.split('/').last.split('.').first);
            return index >= 12 && index <= 30;
          }),
          isEmpty,
        );
        controller.jumpTo(controller.position.maxScrollExtent);
        await settleImages(tester);
        final last = find.byKey(const ValueKey('image-thumbnail-39'));
        expect(last, findsOneWidget);
        expect(tester.getSize(last).shortestSide, greaterThanOrEqualTo(48));
        final beforeTap = requests
            .where((path) => path == '/server/39.png')
            .length;
        await tester.tap(last);
        await settleImages(tester);
        expect(find.text('40 / 40'), findsOneWidget);
        expect(requests.toSet().length, lessThan(40));
        expect(
          tester
              .widget<ChatImageViewport>(find.byType(ChatImageViewport))
              .title,
          '39.png',
        );
        expect(
          requests.where((path) => path == '/server/39.png'),
          hasLength(beforeTap),
        );
        final selected = find.ancestor(
          of: last,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics && widget.properties.label == '39.png',
          ),
        );
        expect(tester.widget<Semantics>(selected).properties.selected, isTrue);
        expect(
          find.descendant(of: strip, matching: find.byType(Text)),
          findsNothing,
        );
        await tester.tap(find.byTooltip('Previous image'));
        await settleImages(tester);
        expect(find.text('39 / 40'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('image-thumbnail-38')),
          findsOneWidget,
        );
        await tester.pageBack();
        await settleImages(tester);
        expect(find.text('+35'), findsOneWidget);
        expect(find.byType(Image), findsNWidgets(5));
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'failed strip images can be selected, retried and replaced without stale originals',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final pending = Completer<Uint8List>();
      var recovered = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProfileMessage(
              message: TranscriptMessage.fromRow({
                'id': 42,
                'role': 'user',
                'content': List.generate(
                  10,
                  (index) => '@image:/server/$index.png',
                ).join('\n'),
              }),
              loadAttachmentImage: (path) async {
                if (path == '/server/5.png' && !recovered) {
                  throw StateError('Unavailable');
                }
                if (path == '/server/6.png') return pending.future;
                return bytes;
              },
            ),
          ),
        ),
      );
      await settleImages(tester);
      await tester.tapAt(tester.getCenter(find.text('+5')));
      await settleImages(tester);
      await tester.tap(find.byKey(const ValueKey('image-thumbnail-5')));
      await settleImages(tester);
      expect(find.text('6 / 10'), findsOneWidget);
      expect(find.byType(ChatImageViewport), findsNothing);
      expect(find.byTooltip('Retry image preview'), findsOneWidget);
      recovered = true;
      await tester.tap(find.byTooltip('Retry image preview'));
      await settleImages(tester);
      expect(
        tester.widget<ChatImageViewport>(find.byType(ChatImageViewport)).title,
        '5.png',
      );
      await tester.tap(find.byTooltip('Next image'));
      await tester.pump();
      await tester.pump(WingMotion.standard);
      await tester.pump();
      expect(find.text('7 / 10'), findsOneWidget);
      expect(find.byType(ChatImageViewport), findsNothing);
      await tester.fling(
        find.byKey(const ValueKey('user-image-gallery-pages')),
        const Offset(-160, 0),
        600,
      );
      await settleImages(tester);
      expect(
        tester.widget<ChatImageViewport>(find.byType(ChatImageViewport)).title,
        '7.png',
      );
      pending.complete(bytes);
      await settleImages(tester);
      expect(
        tester.widget<ChatImageViewport>(find.byType(ChatImageViewport)).title,
        '7.png',
      );
      expect(find.text('8 / 10'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('hidden images remain reachable when the fifth preview fails', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ProfileMessage(
              message: TranscriptMessage.fromRow({
                'id': 42,
                'role': 'user',
                'content': List.generate(
                  6,
                  (index) => '@image:/server/$index.png',
                ).join('\n'),
              }),
              loadAttachmentImage: (path) async {
                if (path == '/server/4.png') {
                  throw StateError('Image unavailable');
                }
                return bytes;
              },
            ),
          ),
        ),
      ),
    );
    await settleImages(tester);
    final gallery = find.byTooltip('Open image gallery, 1 more image');
    await tester.ensureVisible(gallery);
    await tester.tap(gallery);
    await settleImages(tester);
    expect(find.byTooltip('Retry image preview'), findsOneWidget);
    await tester.tap(find.byTooltip('Next image'));
    await settleImages(tester);
    expect(find.text('6 / 6'), findsOneWidget);
    expect(
      tester.widget<ChatImageViewport>(find.byType(ChatImageViewport)).title,
      '5.png',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'passive forty-image snapshots acquire no pixels or gallery authority',
    (tester) async {
      var requests = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProfileMessage(
              message: TranscriptMessage.fromRow({
                'id': 42,
                'role': 'user',
                'content': List.generate(
                  40,
                  (index) => '@image:/server/$index.png',
                ).join('\n'),
              }),
              loadImages: false,
              loadAttachmentImage: (_) async {
                requests++;
                return bytes;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(UserMessageAttachmentTile), findsNWidgets(5));
      expect(find.text('+35'), findsOneWidget);
      await tester.tapAt(tester.getCenter(find.text('+35')));
      await tester.pumpAndSettle();
      expect(requests, 0);
      expect(find.byType(ChatImageViewport), findsNothing);
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion changes images without an animated scroll', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(
          body: ProfileMessage(
            message: TranscriptMessage.fromRow({
              'role': 'user',
              'content': List.generate(
                3,
                (index) => '@image:/server/$index.png',
              ).join('\n'),
            }),
            loadAttachmentImage: (_) async => bytes,
          ),
        ),
      ),
    );
    await settleImages(tester);
    await tester.tap(find.byType(UserMessageAttachmentTile).first);
    await settleImages(tester);
    final pages = find.byKey(const ValueKey('user-image-gallery-pages'));
    final controller = tester.widget<PageView>(pages).controller!;
    await tester.tap(find.byTooltip('Next image'));
    await tester.pump();
    expect(controller.page, 1);
    expect(find.text('2 / 3'), findsOneWidget);
    expect(controller.position.isScrollingNotifier.value, isFalse);
    await tester.tap(find.byKey(const ValueKey('image-thumbnail-2')));
    await tester.pump();
    expect(controller.page, 2);
    expect(find.text('3 / 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'returning during a slide retains zoom and correct paging admission',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProfileMessage(
              message: TranscriptMessage.fromRow({
                'role': 'user',
                'content': '@image:/server/0.png\n@image:/server/1.png',
              }),
              loadAttachmentImage: (_) async => bytes,
            ),
          ),
        ),
      );
      await settleImages(tester);
      await tester.tap(find.byType(UserMessageAttachmentTile).first);
      await settleImages(tester);
      final pages = find.byKey(const ValueKey('user-image-gallery-pages'));
      final transform = tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!;
      transform.value = Matrix4.diagonal3Values(2, 2, 1);
      await tester.pump();
      await tester.tap(find.byTooltip('Next image'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.text('2 / 2'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('image-thumbnail-0')));
      await settleImages(tester);
      expect(find.text('1 / 2'), findsOneWidget);
      expect(transform.value.getMaxScaleOnAxis(), 2);
      expect(
        tester.widget<PageView>(pages).physics,
        isA<NeverScrollableScrollPhysics>(),
      );
      await tester.fling(
        find.byType(InteractiveViewer),
        const Offset(-160, 0),
        600,
      );
      await settleImages(tester);
      expect(find.text('1 / 2'), findsOneWidget);

      // Fully leaving discards the old viewport, so returning creates a normal
      // image with paging enabled rather than retaining stale zoom admission.
      await tester.tap(find.byTooltip('Next image'));
      await settleImages(tester);
      await tester.tap(find.byTooltip('Previous image'));
      await settleImages(tester);
      expect(
        tester
            .widget<InteractiveViewer>(find.byType(InteractiveViewer))
            .transformationController!
            .value
            .getMaxScaleOnAxis(),
        1,
      );
      expect(
        tester.widget<PageView>(pages).physics,
        isNot(isA<NeverScrollableScrollPhysics>()),
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'grid and gallery recover failed previews ${brightness.name} ${scale}x',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 740);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final boundary = GlobalKey();
          var broken = true;
          Completer<Uint8List>? reload;
          var requests = 0;
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: MaterialApp(
                theme: wingTheme(brightness),
                debugShowCheckedModeBanner: false,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: ProfileMessage(
                      message: TranscriptMessage.fromRow({
                        'id': 42,
                        'role': 'user',
                        'content':
                            'Compare the screenshots.\n@image:/server/ready.png\n@image:/server/failed.png\n@image:/server/damaged.png',
                      }),
                      loadAttachmentImage: (path) async {
                        if (path.endsWith('/failed.png') && broken) {
                          requests++;
                          if (reload case final pending?) return pending.future;
                          throw StateError('File could not be read');
                        }
                        if (path.endsWith('/damaged.png') && broken) {
                          return Uint8List.fromList([1, 2, 3]);
                        }
                        return bytes;
                      },
                    ),
                  ),
                ),
              ),
            ),
          );
          Future<void> capture(String state) async {
            if (!const bool.fromEnvironment('CAPTURE_ATTACHMENTS')) return;
            await tester.runAsync(() async {
              final render =
                  boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await render.toImage();
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                'build/attachment-review/error-$state-${brightness.name}-${scale}x.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(data!.buffer.asUint8List());
              image.dispose();
            });
          }

          final failure = find.text('Can’t load image');
          final retry = find.byTooltip('Retry image preview');
          await settleImages(tester);
          expect(failure, findsNWidgets(2));
          expect(failure.first.hitTestable(), findsOneWidget);
          expect(find.byType(StudioErrorFrame), findsNWidgets(2));
          expect(
            tester.getSize(retry.first).shortestSide,
            greaterThanOrEqualTo(48),
          );
          await capture('grid');
          final gallery = find.byTooltip('Open image gallery');
          await tester.ensureVisible(gallery);
          await tester.tap(gallery);
          await settleImages(tester);
          expect(find.text('3 / 3'), findsOneWidget);
          expect(failure.hitTestable(), findsOneWidget);
          await capture('gallery-decode');
          await tester.tap(find.byTooltip('Previous image'));
          await settleImages(tester);
          expect(failure.hitTestable(), findsOneWidget);
          await capture('gallery-acquire');
          reload = Completer<Uint8List>();
          await tester.tap(retry);
          await tester.pump();
          expect(failure.hitTestable(), findsNothing);
          expect(
            find.bySemanticsLabel('Loading attachment').hitTestable(),
            findsOneWidget,
          );
          reload.complete(bytes);
          await settleImages(tester);
          expect(requests, greaterThanOrEqualTo(2));
          expect(failure.hitTestable(), findsNothing);
          await tester.tap(find.byTooltip('Next image'));
          await settleImages(tester);
          expect(failure.hitTestable(), findsOneWidget);
          broken = false;
          await tester.tap(retry);
          await settleImages(tester);
          expect(retry.hitTestable(), findsNothing);
          expect(find.text('3 / 3'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets('gallery cards move continuously, $brightness, ${scale}x', (
        tester,
      ) async {
        tester.view.physicalSize = Size(
          scale == 1 ? 390 : 320,
          scale == 1 ? 844 : 640,
        );
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            builder: (context, child) => RepaintBoundary(
              key: boundary,
              child: MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
            ),
            home: Scaffold(
              body: ProfileMessage(
                message: TranscriptMessage.fromRow({
                  'role': 'user',
                  'content': List.generate(
                    3,
                    (index) => '@image:/server/$index.png',
                  ).join('\n'),
                }),
                loadAttachmentImage: (path) async => captureSamples.isEmpty
                    ? bytes
                    : captureSamples[int.parse(
                        path.split('/').last.split('.').first,
                      )],
              ),
            ),
          ),
        );
        await settleImages(tester);
        await tester.tap(find.byType(UserMessageAttachmentTile).first);
        await settleImages(tester);
        final pages = find.byKey(const ValueKey('user-image-gallery-pages'));
        final controller = tester.widget<PageView>(pages).controller!;
        final strip = find.byKey(
          const PageStorageKey('user-image-gallery-thumbnails'),
        );
        final stripRect = tester.getRect(strip);
        final viewportWidth = tester.getSize(pages).width;

        // Optional native frame sequences allow visual comparison of the
        // complete transition, rather than judging motion from a still image.
        if (scale == 1 &&
            const bool.fromEnvironment('CAPTURE_GALLERY_MOTION')) {
          const root = String.fromEnvironment('GALLERY_MOTION_DIR');
          final directory = Directory('$root/${brightness.name}-$scale');
          await tester.runAsync(() => directory.create(recursive: true));
          for (var frame = 0; frame < 132; frame++) {
            if (frame == 30) await tester.tap(find.byTooltip('Next image'));
            if (frame == 90) await tester.tap(find.byTooltip('Previous image'));
            await tester.pump(const Duration(microseconds: 16667));
            await tester.runAsync(() async {
              final render =
                  boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await render.toImage();
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                '${directory.path}/${frame.toString().padLeft(3, '0')}.png',
              ).writeAsBytes(data!.buffer.asUint8List());
              image.dispose();
            });
          }
          await settleImages(tester);
          expect(find.text('1 / 3'), findsOneWidget);
        }

        // The held drag moves actual image cards before release, in either
        // direction, while the surrounding viewer controls stay put.
        final finger = await tester.startGesture(tester.getCenter(pages));
        await finger.moveBy(const Offset(-30, 0));
        await tester.pump();
        await finger.moveBy(Offset(-viewportWidth * .4, 0));
        await settleImages(tester);
        expect(controller.page, inExclusiveRange(0, .5));
        final first = find.byWidgetPredicate(
          (widget) => widget is ChatImageViewport && widget.title == '0.png',
        );
        final second = find.byWidgetPredicate(
          (widget) => widget is ChatImageViewport && widget.title == '1.png',
        );
        expect(tester.getRect(first).left, lessThan(0));
        expect(tester.getRect(second).left, inExclusiveRange(0, viewportWidth));
        expect(tester.getRect(strip), stripRect);
        if (const bool.fromEnvironment('CAPTURE_ATTACHMENTS')) {
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await render.toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File(
              'build/attachment-review/gallery-motion-${brightness.name}-$scale.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
        final forward = controller.page!;
        await finger.moveBy(const Offset(35, 0));
        await tester.pump();
        expect(controller.page, lessThan(forward));
        await finger.up();
        await settleImages(tester);

        await tester.tap(find.byTooltip('Next image'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        expect(controller.page, inExclusiveRange(0, 1));
        // Catch and reverse an unfinished transition through the selected
        // thumbnail. It must settle on the requested image, without a jump.
        await tester.tap(find.byKey(const ValueKey('image-thumbnail-0')));
        final caught = controller.page!;
        await tester.pump();
        expect(controller.page, closeTo(caught, .001));
        await settleImages(tester);
        expect(controller.page, 0);
        expect(find.text('1 / 3'), findsOneWidget);
        expect(tester.getRect(strip), stripRect);
        expect(tester.takeException(), isNull);
      });

      for (final count in [2, 3, 4, 5, 6, 10, 40]) {
        testWidgets('$count images form a compact grid, $brightness, ${scale}x', (
          tester,
        ) async {
          final width = scale == 1 ? 390.0 : 320.0;
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final boundary = GlobalKey();
          final appBoundary = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => RepaintBoundary(
                key: appBoundary,
                child: MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
              ),
              home: RepaintBoundary(
                key: boundary,
                child: Scaffold(
                  body: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: ProfileMessage(
                      message: TranscriptMessage.fromRow({
                        'id': 42,
                        'role': 'user',
                        'timestamp': 1791676800,
                        'content':
                            'Compare these screenshots.\n${List.generate(count, (index) => '@image:/server/screenshot-$index.png').join('\n')}',
                      }),
                      loadAttachmentImage: (path) async =>
                          captureSamples.isEmpty
                          ? bytes
                          : captureSamples[int.parse(
                                  RegExp(
                                    r'screenshot-(\d+)',
                                  ).firstMatch(path)!.group(1)!,
                                ) %
                                captureSamples.length],
                      showEditAction: true,
                      onEdit: () {},
                      showRestoreAction: true,
                      onRestore: () {},
                    ),
                  ),
                ),
              ),
            ),
          );
          await settleImages(tester);
          final images = find.byType(Image);
          expect(images, findsNWidgets(count > 5 ? 5 : count));
          expect(
            find.text("+${count - 5}"),
            count > 5 ? findsOneWidget : findsNothing,
          );
          final viewport = Offset.zero & Size(width, 900);
          for (var index = 0; index < images.evaluate().length; index++) {
            final bounds = tester.getRect(images.at(index));
            expect(viewport.intersect(bounds), bounds);
            for (
              var next = index + 1;
              next < images.evaluate().length;
              next++
            ) {
              expect(bounds.overlaps(tester.getRect(images.at(next))), isFalse);
            }
          }
          if (count > 5) {
            // The overflow tile deliberately ignores the inner preview's
            // pointer handling; its outer action opens the selected image.
            await tester.tapAt(tester.getCenter(find.text('+${count - 5}')));
            await settleImages(tester);
            expect(find.text('5 / $count'), findsOneWidget);
            await tester.pageBack();
            await settleImages(tester);
          }
          if (count == 40 &&
              const bool.fromEnvironment('CAPTURE_ATTACHMENTS')) {
            await tester.tapAt(tester.getCenter(find.text('+35')));
            await settleImages(tester);
            tester.view.physicalSize = Size(width, scale == 1 ? 844 : 640);
            await settleImages(tester);
            expect(find.text('5 / 40'), findsOneWidget);
            for (final label in ['Previous image', 'Next image']) {
              expect(
                tester.getSize(find.byTooltip(label)).shortestSide,
                greaterThanOrEqualTo(48),
              );
            }
            await tester.runAsync(() async {
              final render =
                  appBoundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await render.toImage();
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                'build/attachment-review/gallery-${brightness.name}-$scale.png',
              ).writeAsBytes(data!.buffer.asUint8List());
              image.dispose();
            });
            tester.view.physicalSize = Size(width, 900);
            await settleImages(tester);
            await tester.pageBack();
            await settleImages(tester);
          }
          expect(tester.takeException(), isNull);
          if ([3, 5, 10, 40].contains(count) &&
              const bool.fromEnvironment('CAPTURE_ATTACHMENTS')) {
            await tester.runAsync(() async {
              final render =
                  boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await render.toImage();
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                'build/attachment-review/grid-$count-${brightness.name}-$scale.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(data!.buffer.asUint8List());
              image.dispose();
            });
          }
          if (count == 3) {
            for (var index = 0; index < count; index++) {
              await tester.tap(images.at(index));
              await settleImages(tester);
              final preview = tester.widget<ChatImageViewport>(
                find.byType(ChatImageViewport),
              );
              expect(preview.title, 'screenshot-$index.png');
              expect(
                preview.bytes,
                orderedEquals(
                  captureSamples.isEmpty
                      ? bytes
                      : captureSamples[index % captureSamples.length],
                ),
              );
              await tester.pageBack();
              await settleImages(tester);
            }
          }
        });
      }
      testWidgets('mixed attachments at 320dp, $brightness, ${scale}x text', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
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
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: ProfileMessage(
                    message: TranscriptMessage.fromRow(
                      saved(
                        text:
                            '@file:"/server/A long attachment filename.pdf"\n\nLook at this.',
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await settleImages(tester);
        expect(find.text('PDF'), findsOneWidget);
        expect(find.byIcon(Icons.insert_drive_file_outlined), findsOneWidget);
        expect(find.byType(UserMessageAttachmentTile), findsNWidgets(2));
        final textRect = tester.getRect(find.text('Look at this.'));
        final imageRect = tester.getRect(find.byType(Image));
        expect(imageRect.top, greaterThan(textRect.bottom));
        expect(imageRect.left, greaterThanOrEqualTo(0));
        expect(imageRect.right, lessThanOrEqualTo(320));
        expect(tester.takeException(), isNull);
        if (const bool.fromEnvironment('CAPTURE_ATTACHMENTS')) {
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await render.toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File(
              'build/attachment-review/${brightness.name}-$scale.png',
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
