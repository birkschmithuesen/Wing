import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:wing/core/models/attachment_draft.dart';
import 'package:wing/core/services/attachment_draft_service.dart';
import 'package:wing/core/services/attachment_image_preflight.dart';

void main() {
  late Directory parent;
  late Directory cache;
  late AttachmentDraftService service;
  late Uint8List png;

  setUp(() async {
    parent = await Directory.systemTemp.createTemp('wing-preview-source-');
    cache = await Directory('${parent.path}/managed').create();
    service = AttachmentDraftService(cacheDirectoryProvider: () async => cache);
    png = image.encodePng(image.Image(width: 8, height: 6));
  });
  tearDown(() => parent.delete(recursive: true));

  Future<AttachmentDraft> stage({
    Uint8List? bytes,
    String name = 'draft-1-0.png',
    String mediaType = 'image/png',
    String? path,
    int? declaredLength,
    bool sanitized = true,
    AttachmentDraftKind kind = AttachmentDraftKind.image,
  }) async {
    final data = bytes ?? png;
    final file = File(path ?? '${cache.path}/$name');
    await file.writeAsBytes(data);
    return AttachmentDraft(
      id: name,
      cachedPath: file.path,
      name: 'Preview image',
      byteLength: declaredLength ?? data.length,
      mediaType: mediaType,
      kind: kind,
      sanitized: sanitized,
    );
  }

  test(
    'managed PNG and JPEG previews preserve exact bytes without draft changes',
    () async {
      for (final (bytes, name, mediaType) in [
        (png, 'draft-1-0.png', 'image/png'),
        (
          image.encodeJpg(image.Image(width: 8, height: 6)),
          'draft-1-1.jpg',
          'image/jpeg',
        ),
      ]) {
        final draft = await stage(
          bytes: bytes,
          name: name,
          mediaType: mediaType,
        );
        expect(
          await service.previewSource(draft).readBytes(),
          orderedEquals(bytes),
        );
        expect(draft.status, AttachmentDraftStatus.ready);
        expect(draft.error, isNull);
        expect(
          await File(draft.cachedPath).readAsBytes(),
          orderedEquals(bytes),
        );
      }
    },
  );

  test(
    'animated PNG remains encoded animation rather than a thumbnail rewrite',
    () async {
      final animation = image.Image(width: 8, height: 6)..frameDuration = 100;
      animation.addFrame(image.Image(width: 8, height: 6)..frameDuration = 200);
      final bytes = image.encodePng(animation);
      final draft = await stage(bytes: bytes);
      final loaded = await service.previewSource(draft).readBytes();
      expect(loaded, orderedEquals(bytes));
      expect(image.decodePng(loaded)!.numFrames, 2);
      expect(await cache.list().length, 1);
    },
  );

  test(
    'preview identity ignores upload errors but captures file and owner identity',
    () async {
      final draft = await stage();
      final source = service.previewSource(draft);
      draft
        ..status = AttachmentDraftStatus.failed
        ..error = 'Upload failed';
      expect(service.previewSource(draft), source);
      expect(service.previewSource(draft).hashCode, source.hashCode);
      final otherOwner = AttachmentDraftService(
        cacheDirectoryProvider: () async => cache,
      );
      expect(otherOwner.previewSource(draft), isNot(source));
      final changed = await stage(name: 'draft-1-1.png');
      expect(service.previewSource(changed), isNot(source));
    },
  );

  test(
    'a completed preview does not retain bytes after the staged file is removed',
    () async {
      final draft = await stage();
      final source = service.previewSource(draft);
      expect(await source.readBytes(), orderedEquals(png));
      await service.removeCachedFile(draft);
      await expectLater(
        source.readBytes(),
        throwsA(isA<AttachmentDraftException>()),
      );
      expect(await File(draft.cachedPath).exists(), isFalse);
      expect(draft.status, AttachmentDraftStatus.ready);
    },
  );

  test(
    'removal during a held preview read cannot recreate or mutate the draft',
    () async {
      final draft = await stage();
      final entered = Completer<void>();
      final directory = Completer<Directory>();
      final heldService = AttachmentDraftService(
        cacheDirectoryProvider: () {
          entered.complete();
          return directory.future;
        },
      );
      final pending = heldService.previewSource(draft).readBytes();
      final rejected = expectLater(
        pending,
        throwsA(isA<AttachmentDraftException>()),
      );
      await entered.future;
      await heldService.removeCachedFile(draft);
      directory.complete(cache);
      await rejected;
      expect(await cache.list().toList(), isEmpty);
      expect(draft.status, AttachmentDraftStatus.ready);
      expect(draft.error, isNull);
    },
  );

  test(
    'foreign files and managed-leaf symlinks are refused without touching targets',
    () async {
      final foreign = File('${parent.path}/draft-1-0.png');
      final draft = await stage(path: foreign.path);
      await expectLater(
        service.previewSource(draft).readBytes(),
        throwsA(isA<AttachmentDraftException>()),
      );
      await Link('${cache.path}/draft-1-1.png').create(foreign.path);
      final linked = AttachmentDraft(
        id: 'draft-1-1.png',
        cachedPath: '${cache.path}/draft-1-1.png',
        name: 'Linked image',
        byteLength: png.length,
        mediaType: 'image/png',
        kind: AttachmentDraftKind.image,
        sanitized: true,
      );
      await expectLater(
        service.previewSource(linked).readBytes(),
        throwsA(isA<AttachmentDraftException>()),
      );
      expect(await foreign.readAsBytes(), orderedEquals(png));
      expect(await Link(linked.cachedPath).exists(), isTrue);
    },
  );

  test(
    'truncated and larger-than-declared files fail without deleting local work',
    () async {
      for (final difference in [-1, 1]) {
        final draft = await stage(declaredLength: png.length + difference);
        await expectLater(
          service.previewSource(draft).readBytes(),
          throwsA(isA<AttachmentDraftException>()),
        );
        expect(await File(draft.cachedPath).readAsBytes(), orderedEquals(png));
        expect(draft.error, isNull);
      }
    },
  );

  test(
    'generic, unsanitized and oversized metadata never invokes filesystem lookup',
    () async {
      var reads = 0;
      final counting = AttachmentDraftService(
        cacheDirectoryProvider: () async {
          reads++;
          return cache;
        },
      );
      for (final draft in [
        await stage(kind: AttachmentDraftKind.genericFile),
        await stage(sanitized: false),
        await stage(declaredLength: maxAttachmentImageOutputBytes + 1),
      ]) {
        await expectLater(
          counting.previewSource(draft).readBytes(),
          throwsA(isA<AttachmentDraftException>()),
        );
      }
      expect(reads, 0);
      expect(await cache.list().length, 1);
    },
  );

  test(
    'actual malformed or mismatched image bytes are rejected before native decode',
    () async {
      for (final draft in [
        await stage(bytes: Uint8List.fromList([1, 2, 3, 4])),
        await stage(name: 'draft-1-1.png', mediaType: 'image/jpeg'),
        await stage(name: 'unmanaged.png'),
      ]) {
        await expectLater(
          service.previewSource(draft).readBytes(),
          throwsA(isA<AttachmentDraftException>()),
        );
        expect(await File(draft.cachedPath).exists(), isTrue);
        expect(draft.status, AttachmentDraftStatus.ready);
      }
    },
  );
}
