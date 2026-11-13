import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/chat_output.dart';
import 'package:wing/core/services/chat_outputs_session.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/remote_files_client.dart';

void main() {
  for (final extension in ['png', 'svg']) {
    test('large remote $extension can download but cannot render', () async {
      final file = RemoteFileDownload(
        filename: 'image.$extension',
        bytes: Uint8List(maxFilePreviewBytes + 1),
      );
      final owner = ChatOutputsSession(
        loadHistory: (_) async => throw UnimplementedError(),
        download: (_) async => file,
        readText: (_) async => throw UnimplementedError(),
      );
      addTearDown(owner.dispose);
      final output = ChatOutput(
        kind: ChatOutputKind.image,
        path: '/srv/image.$extension',
        url: null,
        label: file.filename,
      );
      await expectLater(owner.prepare(output), throwsFormatException);
      expect(await owner.download(output.path!), same(file));
    });
  }

  ChatOutputsSession imageHistory(
    String target,
    List<RemoteFileDownload> deliveries,
  ) {
    final owner = ChatOutputsSession(
      loadHistory: (offset) async => ProfileHistoryPage(
        'chat',
        [
          {
            'role': 'tool',
            'name': 'generate_image',
            'content': {'artifact_image': target},
          },
        ],
        offset,
        500,
        isComplete: true,
      ),
      download: (_) async => throw StateError('must not download'),
      readText: (_) async => throw StateError('must not read text'),
      deliver: (file) async => deliveries.add(file),
    );
    addTearDown(owner.dispose);
    return owner;
  }

  for (final encoding in ['encoded', 'base64', 'percent']) {
    test(
      'oversized $encoding history image cannot preview or share and permits recovery',
      () async {
        final target = switch (encoding) {
          'encoded' => 'data:image/png;base64,${'A' * (45 * 1024 * 1024)}',
          'base64' =>
            'data:image/png;base64,${base64Encode(Uint8List(maxFilePreviewBytes + 1))}',
          _ => 'data:image/png,${'A' * maxFilePreviewBytes}%41',
        };
        final deliveries = <RemoteFileDownload>[];
        final owner = imageHistory(target, deliveries);
        await owner.load();
        final oversized = owner.observation.outputs.single;
        await expectLater(owner.prepare(oversized), throwsFormatException);
        await expectLater(() async {
          final preview = await owner.prepare(oversized);
          await owner.share(preview.file!);
        }, throwsFormatException);
        expect(deliveries, isEmpty);
        final valid = await owner.prepare(
          const ChatOutput(
            kind: ChatOutputKind.image,
            path: null,
            url: 'data:image/png;base64,AQID',
            label: 'Embedded image',
          ),
        );
        await owner.share(valid.file!);
        expect(deliveries.single.bytes, [1, 2, 3]);
        expect(owner.observation.loading, isFalse);
      },
    );
  }

  test(
    'an embedded image at the decoded limit can preview and share',
    () async {
      final deliveries = <RemoteFileDownload>[];
      final owner = imageHistory(
        'data:image/png;base64,${base64Encode(Uint8List(maxFilePreviewBytes))}',
        deliveries,
      );
      await owner.load();
      final preview = await owner.prepare(owner.observation.outputs.single);
      expect(preview.kind, OutputPreviewKind.image);
      expect(preview.file!.filename, 'image.png');
      expect(preview.file!.bytes.length, maxFilePreviewBytes);
      await owner.share(preview.file!);
      expect(deliveries.single, same(preview.file));
    },
  );

  test(
    'percent-encoded SVG keeps its exact preview and shared bytes',
    () async {
      const source =
          '<svg xmlns="http://www.w3.org/2000/svg"><text>ok</text></svg>';
      final deliveries = <RemoteFileDownload>[];
      final owner = imageHistory(
        'data:image/svg+xml,${Uri.encodeComponent(source)}',
        deliveries,
      );
      await owner.load();
      final preview = await owner.prepare(owner.observation.outputs.single);
      expect(preview.kind, OutputPreviewKind.svg);
      expect(preview.svgSource, source);
      await owner.share(preview.file!);
      expect(utf8.decode(deliveries.single.bytes), source);
    },
  );

  test(
    'retiring from a loading observation does not dispatch history',
    () async {
      var reads = 0;
      final owner = ChatOutputsSession(
        loadHistory: (_) async {
          reads++;
          throw StateError('must not read');
        },
        download: (_) async => throw StateError('must not download'),
        readText: (_) async => throw StateError('must not read text'),
      );
      owner.addListener(owner.dispose);
      await owner.load();
      expect(reads, 0);
      await owner.load(refresh: true);
      expect(reads, 0);
      owner.dispose();
    },
  );
}
