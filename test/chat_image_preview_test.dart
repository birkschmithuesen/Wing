import 'package:wing/core/models/transcript_message.dart';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:wing/core/widgets/chat_image_preview.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';
import 'helpers/pump_markdown_widget.dart';

void main() {
  testWidgets('image preview opens on tap and returns to the conversation', (
    tester,
  ) async {
    await tester.pumpMarkdownWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileMessage(
            message: TranscriptMessage.fromRow(const {
              'role': 'assistant',
              'content': '![Result chart](/srv/chart.png)',
            }),
            loadAttachmentImage: (_) async => Uint8List.fromList(
              img.encodePng(img.Image(width: 120, height: 80)),
            ),
          ),
        ),
      ),
    );
    final thumbnail = find.descendant(
      of: find.byType(MarkdownMessageContent),
      matching: find.byType(Image),
    );
    await tester.pump();
    await tester.runAsync(
      () => precacheImage(
        tester.widget<Image>(thumbnail).image,
        tester.element(thumbnail),
      ),
    );
    await tester.pumpAndSettle();
    expect(thumbnail, findsOneWidget);
    await tester.tap(thumbnail);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final original = find.descendant(
      of: find.byType(ChatImagePreview),
      matching: find.byType(Image),
    );
    await tester.runAsync(
      () => precacheImage(
        tester.widget<Image>(original).image,
        tester.element(original),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ChatImagePreview), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(
      tester.widget<ChatImagePreview>(find.byType(ChatImagePreview)).bytes,
      isNotNull,
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ChatImagePreview), findsNothing);
    expect(thumbnail, findsOneWidget);
  });

  testWidgets('failed image has an external-open fallback', (tester) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: ChatImagePreview(
          bytes: Uint8List.fromList([0, 1, 2, 3]),
          title: 'Result',
          onOpenExternal: () async {
            opened = true;
            return null;
          },
        ),
      ),
    );
    final image = find.byType(Image);
    await tester.runAsync(
      () => precacheImage(
        tester.widget<Image>(image).image,
        tester.element(image),
        onError: (_, _) {},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('could not be previewed'), findsOneWidget);
    expect(find.text('Open in browser'), findsNothing);
    final recovery = find.descendant(
      of: find.byType(ChatImageViewport),
      matching: find.byTooltip('Open in browser'),
    );
    expect(recovery.hitTestable(), findsOneWidget);
    await tester.tap(recovery);
    expect(opened, isTrue);
  });
  testWidgets('share failure stays anchored and retires when retried', (
    tester,
  ) async {
    var delivery = Completer<String?>();
    await tester.pumpWidget(
      MaterialApp(
        home: ChatImagePreview(
          bytes: Uint8List.fromList(
            img.encodePng(img.Image(width: 16, height: 16)),
          ),
          title: 'Result',
          actionLabel: 'Save or share',
          actionIcon: Icons.share_outlined,
          onOpenExternal: () => delivery.future,
        ),
      ),
    );
    final image = find.byType(Image);
    await tester.runAsync(
      () => precacheImage(
        tester.widget<Image>(image).image,
        tester.element(image),
      ),
    );
    await tester.pumpAndSettle();
    final share = find.byTooltip('Save or share');
    final error = find.text('Could not share this image.');
    final anchor = tester.getRect(share);
    await tester.tap(share);
    await tester.pump();
    expect(find.byTooltip('Preparing image'), findsOneWidget);
    delivery.complete('Could not share this image.');
    await tester.pumpAndSettle();
    expect(error, findsOneWidget);
    expect(tester.getRect(error).top, greaterThan(anchor.bottom));
    expect(tester.getRect(share), anchor);
    delivery = Completer<String?>();
    await tester.tap(share);
    await tester.pumpAndSettle();
    expect(error, findsNothing);
    delivery.complete(null);
    await tester.pumpAndSettle();
    expect(share.hitTestable(), findsOneWidget);
  });
}
