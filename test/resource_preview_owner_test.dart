import 'package:wing/core/models/chat_output.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/transcript_resource_session.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/owned_remote_files.dart';
import 'package:wing/core/services/pdf_preview_service.dart';
import 'package:wing/core/services/remote_files_client.dart';

class _Files implements RemoteFilesDataSource {
  final downloadResult = Completer<RemoteFileDownload>();
  String? profile;
  String? session;
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
  }) {
    profile = profileName;
    session = storedSessionId;
    return downloadResult.future;
  }
}

class _Pdf extends PdfPreviewService {
  final rendering = Completer<Uint8List>();
  final renderEntered = Completer<void>();
  final closed = <String>[];
  @override
  Future<PdfDocument> open(Uint8List bytes) async =>
      const PdfDocument('captured', 2);
  @override
  Future<Uint8List> render(PdfDocument document, int page) {
    renderEntered.complete();
    return rendering.future;
  }

  @override
  Future<void> close(PdfDocument document) async => closed.add(document.id);
}

void main() {
  test(
    'trace retirement rejects late image and viewer bytes under the captured child',
    () async {
      final source = _Files();
      var releases = 0;
      final visit = TranscriptResourceSession(
        files: OwnedRemoteFiles(
          source: source,
          profileName: 'child-profile',
          storedSessionId: 'nested-session',
          release: () => releases++,
        ),
        loadHistory: (offset) async => ProfileHistoryPage(
          'nested-session',
          [],
          offset,
          20,
          isComplete: true,
        ),
        createSkillReader: (_) => throw UnimplementedError(),
      );
      final viewer = visit.createOutputsSession();
      addTearDown(viewer.dispose);
      final image = visit.loadImage('relative/image.png');
      final preview = viewer.prepare(
        explicitRemoteFileOutput('relative/image.png')!,
      );
      final imageFailure = expectLater(image, throwsStateError);
      final previewFailure = expectLater(preview, throwsStateError);
      expect(source.profile, 'child-profile');
      expect(source.session, 'nested-session');
      visit.dispose();
      source.downloadResult.complete(
        RemoteFileDownload(filename: 'image.png', bytes: [1, 2, 3]),
      );
      await Future.wait([imageFailure, previewFailure]);
      await expectLater(visit.loadImage('late.png'), throwsStateError);
      expect(visit.createOutputsSession, throwsStateError);
      visit.dispose();
      expect(releases, 1);
    },
  );

  test(
    'trace output history stays on its captured reader and rejects late history',
    () async {
      final source = _Files();
      final history = Completer<ProfileHistoryPage>();
      final offsets = <int>[];
      final visit = TranscriptResourceSession(
        files: OwnedRemoteFiles(
          source: source,
          profileName: 'child-profile',
          storedSessionId: 'nested-session',
          release: () {},
        ),
        loadHistory: (offset) {
          offsets.add(offset);
          return history.future;
        },
        createSkillReader: (_) => throw UnimplementedError(),
      );
      final outputs = visit.createOutputsSession();
      addTearDown(outputs.dispose);
      final pending = outputs.load();
      visit.dispose();
      history.complete(
        ProfileHistoryPage(
          'nested-session',
          [
            {'id': 1, 'role': 'assistant', 'content': '[Late report](late.md)'},
          ],
          0,
          20,
          isComplete: true,
        ),
      );
      await pending;
      expect(offsets, [0]);
      expect(outputs.observation.outputs, isEmpty);
      expect(outputs.observation.error, isNotNull);
    },
  );

  test(
    'oversized HTML retains its original for sharing after preview refusal',
    () async {
      final file = RemoteFileDownload(
        filename: 'report.html',
        bytes: Uint8List(maxFilePreviewBytes + 1),
      );
      RemoteFileDownload? shared;
      final reader = HtmlPreviewReader(
        download: () async => file,
        share: (value) async => shared = value,
      );
      addTearDown(reader.dispose);
      await reader.load();
      expect(reader.observation.source, isNull);
      expect(reader.observation.error, contains('too large to preview'));
      expect(reader.observation.hasFile, isTrue);
      expect(await reader.share(), isNull);
      expect(shared, same(file));
    },
  );

  const encodedLimit = 45 * 1024 * 1024;
  const prefix = 'data:image/svg+xml,';
  for (final expanded in [('漢', 9), ('\u0000', 3)]) {
    test(
      'embedded image rejects normalized payload above limit: ${expanded.$2}',
      () async {
        final count = (encodedLimit - prefix.length) ~/ expanded.$2 + 1;
        final target = '$prefix${expanded.$1 * count}';
        expect(target.length, lessThan(encodedLimit));
        expect(() {
          decodeEmbeddedImage(target);
        }, throwsFormatException);
        await expectLater(() async {
          await acquireUserAttachmentImage(target, null);
        }, throwsFormatException);
        await expectLater(() async {
          await acquireToolReceiptImage(target, null);
        }, throwsFormatException);
      },
    );
  }
  test('Unicode normalization admits the exact encoded boundary', () {
    final count = (encodedLimit - prefix.length) ~/ 9;
    final remainder = (encodedLimit - prefix.length) % 9;
    final data = decodeEmbeddedImage('$prefix${'漢' * count}${'a' * remainder}');
    expect(data.mimeType, 'image/svg+xml');
    expect(data.bytes.length, count * 3 + remainder);
    expect(data.bytes.take(3), utf8.encode('漢'));
    expect(
      data.bytes.skip(data.bytes.length - remainder),
      List.filled(remainder, 97),
    );
  });
  test('Unicode SVG and mixed escapes retain exact UTF-8 bytes', () async {
    const source = '<svg><text>漢é🦉% A#[]</text></svg>';
    final expected = utf8.encode(source);
    for (final target in [
      '$prefix$source',
      '$prefix${Uri.encodeComponent(source)}',
      'data:image/svg+xml;base64,${base64Encode(expected).replaceAll('=', '')}',
    ]) {
      final data = decodeEmbeddedImage(target);
      expect(data.bytes, expected);
      final image = await acquireUserAttachmentImage(target, null);
      expect(image.bytes, expected);
    }
    // Invalid percent escapes are literal text under UriData's normalization.
    expect(decodeEmbeddedImage('$prefix%zz%').bytes, utf8.encode('%zz%'));
  });
  test(
    'data locators remain unavailable to ordinary conversation images',
    () async {
      var reads = 0;
      for (final target in ['${prefix}x', 'DATA:image/png;base64,AQID']) {
        await expectLater(
          acquireConversationImage(target, (_) async {
            reads++;
            return Uint8List.fromList([1]);
          }),
          throwsFormatException,
        );
      }
      expect(reads, 0);
    },
  );

  test(
    'captured transport releases once and rejects its late result',
    () async {
      final source = _Files();
      var releases = 0;
      final owner = OwnedRemoteFiles(
        source: source,
        profileName: 'captured-profile',
        storedSessionId: 'captured-session',
        release: () => releases++,
      );
      final pending = owner.download('relative.png');
      final rejected = expectLater(pending, throwsStateError);
      owner.dispose();
      owner.dispose();
      source.downloadResult.complete(
        RemoteFileDownload(filename: 'relative.png', bytes: [1]),
      );
      await rejected;
      expect(releases, 1);
      expect(source.profile, 'captured-profile');
      expect(source.session, 'captured-session');
      await expectLater(owner.download('later.png'), throwsStateError);
    },
  );

  test('HTML retains the original failed decode for a single share', () async {
    final file = RemoteFileDownload(filename: 'report.html', bytes: [0xff]);
    final sharing = Completer<void>();
    var downloads = 0;
    var shares = 0;
    final reader = HtmlPreviewReader(
      download: () async {
        downloads++;
        return file;
      },
      share: (original) {
        expect(original, same(file));
        shares++;
        return sharing.future;
      },
    );
    addTearDown(reader.dispose);
    await reader.load();
    expect(reader.observation.source, isNull);
    expect(reader.observation.hasFile, isTrue);
    expect(reader.observation.error, contains("can't be read here"));
    final pending = reader.share();
    await reader.share();
    await reader.load();
    expect(shares, 1);
    expect(downloads, 1);
    expect(reader.observation.sharing, isTrue);
    sharing.complete();
    expect(await pending, isNull);
    expect(reader.observation.sharing, isFalse);
  });

  test(
    'closing HTML during download discards bytes and publications',
    () async {
      final download = Completer<RemoteFileDownload>();
      var publications = 0;
      final reader = HtmlPreviewReader(
        download: () => download.future,
        share: (_) async => fail('A closed HTML reader must not share'),
      )..addListener(() => publications++);
      final pending = reader.load();
      expect(publications, 1);
      reader.dispose();
      download.complete(
        RemoteFileDownload(
          filename: 'report.html',
          bytes: utf8.encode('<h1>x</h1>'),
        ),
      );
      await pending;
      expect(publications, 1);
      expect(reader.observation.source, isNull);
      expect(reader.observation.hasFile, isFalse);
      await reader.share();
    },
  );

  test(
    'closing PDF waits for the captured render before releasing native handle',
    () async {
      final service = _Pdf();
      final reader = service.createReader(
        () async => RemoteFileDownload(filename: 'report.pdf', bytes: [1]),
      );
      var publications = 0;
      reader.addListener(() => publications++);
      final pending = reader.load();
      await service.renderEntered.future;
      final beforeClose = publications;
      reader.dispose();
      expect(service.closed, isEmpty);
      service.rendering.complete(Uint8List.fromList([1, 2, 3]));
      await pending;
      expect(service.closed, ['captured']);
      expect(publications, beforeClose);
      expect(reader.observation.pageImage, isNull);
      reader.dispose();
      expect(service.closed, ['captured']);
    },
  );

  test(
    'decoded image facts copy bytes and retain distinct address admission',
    () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final image = await acquireUserAttachmentImage(
        'remote.png',
        (_) async => bytes,
      );
      bytes[0] = 9;
      expect(image.bytes, [1, 2, 3]);
      expect(() => image.bytes![0] = 9, throwsUnsupportedError);
      var calls = 0;
      final windows = await acquireConversationImage(r'C:\images\x.png', (
        _,
      ) async {
        calls++;
        return Uint8List.fromList([4]);
      });
      expect(windows.bytes, [4]);
      expect(calls, 1);
      await expectLater(
        acquireUserAttachmentImage(r'C:\images\x.png', (_) async => bytes),
        throwsFormatException,
      );
      await expectLater(
        acquireConversationImage('file:///private/x.png', (_) async => bytes),
        throwsFormatException,
      );
      await expectLater(
        acquireUserAttachmentImage('data:text/plain;base64,eA==', null),
        throwsFormatException,
      );
      final embedded = await acquireUserAttachmentImage(
        'data:image/png;base64,AQID',
        null,
      );
      expect(embedded.bytes, [1, 2, 3]);
    },
  );
}
