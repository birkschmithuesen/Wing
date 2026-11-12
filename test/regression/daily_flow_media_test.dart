import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/transcript_message.dart';
import '../helpers/pump_markdown_widget.dart';
import 'package:wing/core/widgets/chat_image_preview.dart';
import 'package:wing/core/widgets/deliverable_attachment.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'package:wing/core/controllers/voice_output_controller.dart'
    show spokenReplyText;

final _png = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7'
    'gP9i18U1AAAAABJRU5ErkJggg==',
  ),
);

// SETUP
// (the only lines that may change at the merge): how the message gets
// its image loader. Pre-merge: onLoadRemoteImage (ChatOutput). Post-merge:
// loadAttachmentImage (String path) feeding upstream's ChatInlineImage.
Widget _message(String text, Future<Uint8List> Function(String path) load) =>
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProfileMessage(
            message: TranscriptMessage.fromRow({
              'role': 'assistant',
              'content': text,
            }),
            loadAttachmentImage: load,
          ),
        ),
      ),
    );
// SETUP

void main() {
  group('R3 media', () {
    testWidgets('R3: an image deliverable shows inline and opens the preview on tap', (
      tester,
    ) async {
      final requested = <String>[];
      await tester.pumpMarkdownWidget(
        _message('MEDIA:/srv/screenshot.png', (path) async {
          requested.add(path);
          return _png;
        }),
      );
      final inline = find.descendant(
        of: find.byType(DeliverableAttachment),
        matching: find.byType(Image),
      );
      await tester.pump();
      await tester.runAsync(
        () => precacheImage(
          tester.widget<Image>(inline).image,
          tester.element(inline),
        ),
      );
      await tester.pumpAndSettle();
      expect(inline, findsOneWidget);
      expect(requested, ['/srv/screenshot.png']);
      await tester.tap(inline);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ChatImagePreview), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
    test('R3: MEDIA reference lines are not read aloud', () {
      expect(
        spokenReplyText('Text.\n\nMEDIA:/a/b/c.png'),
        'Text.',
      );
      expect(
        spokenReplyText('Text.\n\nMEDIA: "/a b/c.png"'),
        'Text.',
      );
      expect(
        spokenReplyText('Text.\n\n`MEDIA:/x.pdf`'),
        'Text.',
      );
      expect(
        spokenReplyText('Streaming media players are great.'),
        'Streaming media players are great.',
      );
    });
  });
}
