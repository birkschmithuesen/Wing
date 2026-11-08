import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:wing/core/models/attachment_draft.dart';
import 'package:wing/core/presentation/attachment_preview_image.dart';
import 'package:wing/core/services/attachment_draft_service.dart';
import 'package:wing/core/widgets/composer_attachment_tile.dart';
import 'package:wing/core/widgets/chat_image_preview.dart';

Future<ui.Image> _decode(ImageProvider provider) async {
  final stream = provider.resolve(ImageConfiguration.empty);
  final loaded = Completer<ui.Image>();
  final listener = ImageStreamListener(
    (info, _) {
      if (!loaded.isCompleted) loaded.complete(info.image.clone());
    },
    onError: (Object error, StackTrace? stack) {
      if (!loaded.isCompleted) loaded.completeError(error, stack);
    },
  );
  stream.addListener(listener);
  try {
    return await loaded.future;
  } finally {
    stream.removeListener(listener);
  }
}

Future<({Directory cache, AttachmentDraft draft})> _stage(
  Uint8List bytes,
) async {
  final cache = await Directory.systemTemp.createTemp('wing-preview-provider-');
  final file = File('${cache.path}/draft-1-0.png');
  await file.writeAsBytes(bytes);
  addTearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await cache.delete(recursive: true);
  });
  return (
    cache: cache,
    draft: AttachmentDraft(
      id: 'draft-1-0.png',
      cachedPath: file.path,
      name: 'Preview image',
      byteLength: bytes.length,
      mediaType: 'image/png',
      kind: AttachmentDraftKind.image,
      sanitized: true,
    ),
  );
}

Future<void> _settleNative(WidgetTester tester, bool Function() settled) async {
  for (var attempt = 0; attempt < 400 && !settled(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  expect(
    settled(),
    isTrue,
    reason: 'Controlled native image work must settle.',
  );
}

void main() {
  for (final synchronous in [true, false]) {
    testWidgets('draft viewer catches immediate read failure $synchronous', (
      tester,
    ) async {
      final bytes = Uint8List.fromList(
        image.encodePng(image.Image(width: 1, height: 1)),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ComposerAttachmentTile(
              name: 'Draft.png',
              kind: AttachmentDraftKind.image,
              previewImage: MemoryImage(bytes),
              readPreview: () {
                if (synchronous) throw StateError('Unavailable');
                return Future.error(StateError('Unavailable'));
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Preview Draft.png'));
      await tester.pumpAndSettle();
      expect(find.text('This image could not be previewed.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final outcome in ['success', 'failure', 'departure']) {
    testWidgets('shared draft image viewer handles $outcome', (tester) async {
      final pending = Completer<Uint8List>();
      final bytes = Uint8List.fromList(
        image.encodePng(image.Image(width: 1, height: 1)),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ComposerAttachmentTile(
              name: 'Draft.png',
              kind: AttachmentDraftKind.image,
              previewImage: MemoryImage(bytes),
              readPreview: () => pending.future,
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Preview Draft.png'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Draft.png'), findsOneWidget);
      if (outcome == 'departure') {
        await tester.pageBack();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
      }
      if (outcome == 'failure') {
        pending.completeError(StateError('Preview unavailable'));
      } else {
        pending.complete(bytes);
      }
      await tester.pump();
      if (outcome == 'success') {
        await _settleNative(
          tester,
          () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
        );
      }
      await tester.pumpAndSettle();
      expect(
        find.byType(ChatImagePreview),
        outcome == 'success' ? findsOneWidget : findsNothing,
      );
      if (outcome == 'failure') {
        expect(find.text('This image could not be previewed.'), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
      if (outcome != 'success') {
        expect(find.byType(ComposerAttachmentTile), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('composer preview bounds both decoded axes for a valid tall image', (
    tester,
  ) async {
    final cache = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('wing-preview-image-'),
    ))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await tester.runAsync(() => cache.delete(recursive: true));
    });
    final service = AttachmentDraftService(
      cacheDirectoryProvider: () async => cache,
    );
    final draft = (await tester.runAsync(
      () => service.prepareImageBytes(
        bytes: image.encodePng(image.Image(width: 512, height: 4096)),
        displayName: 'Tall image.png',
        existingDrafts: const [],
      ),
    ))!;
    // A genuine staged, sanitized product image, rather than malformed metadata.
    expect(draft.sanitized, isTrue);
    expect(
      await tester.runAsync(() => File(draft.cachedPath).exists()),
      isTrue,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: ComposerAttachmentTile(
            name: draft.name,
            kind: draft.kind,
            previewImage: AttachmentPreviewImage(service.previewSource(draft)),
          ),
        ),
      ),
    );
    final tile = find.byKey(const ValueKey('composer-image-thumbnail'));
    final preview = tester.widget<Image>(
      find.descendant(of: tile, matching: find.byType(Image)),
    );
    final stream = preview.image.resolve(ImageConfiguration.empty);
    final decoded = Completer<void>();
    ui.Image? bitmap;
    Object? decodeError;
    final listener = ImageStreamListener(
      (info, _) {
        if (!decoded.isCompleted) {
          bitmap = info.image.clone();
          decoded.complete();
        }
      },
      onError: (Object error, StackTrace? stack) {
        if (!decoded.isCompleted) {
          decodeError = error;
          decoded.complete();
        }
      },
    );
    stream.addListener(listener);
    try {
      for (var attempt = 0; attempt < 400 && !decoded.isCompleted; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(
        decoded.isCompleted,
        isTrue,
        reason:
            'Native image loading must settle before inspecting decode bounds.',
      );
      expect(
        decodeError,
        isNull,
        reason: 'A real valid image must decode before inspecting its size.',
      );
      final resource = bitmap!;
      try {
        // Assert the decoded resource itself, not merely the tile's layout size.
        expect(resource.width, greaterThan(0));
        expect(resource.height, greaterThan(0));
        expect(resource.width, lessThanOrEqualTo(256));
        expect(resource.height, lessThanOrEqualTo(256));
        expect(resource.width / resource.height, closeTo(512 / 4096, 0.01));
      } finally {
        resource.dispose();
      }
    } finally {
      stream.removeListener(listener);
    }
    expect(tester.takeException(), isNull);
  });

  for (final (width, height, expectedWidth, expectedHeight) in [
    (4096, 512, 256, 32),
    (1, 4096, 1, 256),
    (4096, 1, 256, 1),
    (8, 6, 8, 6),
  ]) {
    test(
      'preview decoder preserves bounded positive dimensions for $width x $height',
      () async {
        final staged = await _stage(
          image.encodePng(image.Image(width: width, height: height)),
        );
        final service = AttachmentDraftService(
          cacheDirectoryProvider: () async => staged.cache,
        );
        final bitmap = await _decode(
          AttachmentPreviewImage(service.previewSource(staged.draft)),
        );
        try {
          expect(bitmap.width, expectedWidth);
          expect(bitmap.height, expectedHeight);
        } finally {
          bitmap.dispose();
        }
      },
    );
  }

  test(
    'unchanged upload state and simultaneous equal providers share one preview read',
    () async {
      final staged = await _stage(
        image.encodePng(image.Image(width: 8, height: 6)),
      );
      var reads = 0;
      final service = AttachmentDraftService(
        cacheDirectoryProvider: () async {
          reads++;
          return staged.cache;
        },
      );
      final first = AttachmentPreviewImage(service.previewSource(staged.draft));
      staged.draft
        ..status = AttachmentDraftStatus.failed
        ..error = 'Upload failed';
      final second = AttachmentPreviewImage(
        service.previewSource(staged.draft),
      );
      expect(second, first);
      final frames = await Future.wait([_decode(first), _decode(second)]);
      try {
        expect(reads, 1);
        final next = await _decode(
          AttachmentPreviewImage(service.previewSource(staged.draft)),
        );
        try {
          expect(reads, 1);
          expect(next.width, 8);
        } finally {
          next.dispose();
        }
      } finally {
        for (final frame in frames) {
          frame.dispose();
        }
      }
    },
  );

  testWidgets(
    'unavailable preview renders fallback without changing draft or removal action',
    (tester) async {
      final staged = (await tester.runAsync(
        () => _stage(image.encodePng(image.Image(width: 8, height: 6))),
      ))!;
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      final service = AttachmentDraftService(
        cacheDirectoryProvider: () async => staged.cache,
      );
      staged.draft
        ..status = AttachmentDraftStatus.failed
        ..error = 'Upload failed';
      await tester.runAsync(() => service.removeCachedFile(staged.draft));
      var removes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: ComposerAttachmentTile(
              name: staged.draft.name,
              kind: staged.draft.kind,
              error: staged.draft.error,
              previewImage: AttachmentPreviewImage(
                service.previewSource(staged.draft),
              ),
              onRemove: () => removes++,
            ),
          ),
        ),
      );
      await _settleNative(
        tester,
        () => find.byIcon(Icons.broken_image_outlined).evaluate().isNotEmpty,
      );
      expect(find.byTooltip('Upload failed'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove Preview image'));
      expect(removes, 1);
      expect(staged.draft.status, AttachmentDraftStatus.failed);
      expect(staged.draft.error, 'Upload failed');
      expect(
        await tester.runAsync(() => staged.cache.list().toList()),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a removed held preview cannot replace the next visible image or recreate its file',
    (tester) async {
      final staged = (await tester.runAsync(
        () => _stage(image.encodePng(image.Image(width: 8, height: 6))),
      ))!;
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      final entered = Completer<void>();
      final directory = Completer<Directory>();
      final heldService = AttachmentDraftService(
        cacheDirectoryProvider: () {
          if (!entered.isCompleted) entered.complete();
          return directory.future;
        },
      );
      final retired = AttachmentPreviewImage(
        heldService.previewSource(staged.draft),
      );
      var retiredSettled = false;
      final refused = expectLater(
        _decode(retired),
        throwsA(isA<AttachmentDraftException>()),
      );
      refused.then<void>(
        (_) {
          retiredSettled = true;
        },
        onError: (Object error, StackTrace stack) {
          retiredSettled = true;
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: ComposerAttachmentTile(
              name: staged.draft.name,
              kind: staged.draft.kind,
              previewImage: retired,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(entered.isCompleted, isTrue);

      final bytes = image.encodePng(image.Image(width: 3, height: 5));
      final replacementFile = File('${staged.cache.path}/draft-1-1.png');
      await tester.runAsync(() => replacementFile.writeAsBytes(bytes));
      final replacementDraft = AttachmentDraft(
        id: 'draft-1-1.png',
        cachedPath: replacementFile.path,
        name: 'Replacement',
        byteLength: bytes.length,
        mediaType: 'image/png',
        kind: AttachmentDraftKind.image,
        sanitized: true,
      );
      final service = AttachmentDraftService(
        cacheDirectoryProvider: () async => staged.cache,
      );
      final replacement = AttachmentPreviewImage(
        service.previewSource(replacementDraft),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: ComposerAttachmentTile(
              name: replacementDraft.name,
              kind: replacementDraft.kind,
              previewImage: replacement,
            ),
          ),
        ),
      );
      ui.Image? nextImage;
      Object? nextError;
      _decode(replacement).then<void>(
        (value) {
          nextImage = value;
        },
        onError: (Object error, StackTrace stack) {
          nextError = error;
        },
      );
      await tester.runAsync(() => heldService.removeCachedFile(staged.draft));
      directory.complete(staged.cache);
      await _settleNative(
        tester,
        () => retiredSettled && (nextImage != null || nextError != null),
      );
      await refused;
      try {
        expect(nextError, isNull);
        expect(nextImage!.width, 3);
        expect(nextImage!.height, 5);
        expect(tester.widget<Image>(find.byType(Image)).image, replacement);
        expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
        expect(staged.draft.status, AttachmentDraftStatus.ready);
        expect(staged.draft.error, isNull);
        expect(
          await tester.runAsync(() => File(staged.draft.cachedPath).exists()),
          isFalse,
        );
        expect(
          await tester.runAsync(() => replacementFile.readAsBytes()),
          orderedEquals(bytes),
        );
        expect(await tester.runAsync(() => staged.cache.list().length), 1);
        expect(tester.takeException(), isNull);
      } finally {
        nextImage?.dispose();
      }
    },
  );

  testWidgets(
    'generic tile retains filename warning and delegated removal without image work',
    (tester) async {
      var removes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ComposerAttachmentTile(
                name: 'notes.txt',
                kind: AttachmentDraftKind.genericFile,
                error: 'Upload failed',
                previewImage: null,
                onRemove: () => removes++,
              ),
            ),
          ),
        ),
      );
      expect(find.byType(Image), findsNothing);
      expect(find.text('notes.txt'), findsOneWidget);
      expect(find.byTooltip('Upload failed'), findsOneWidget);
      await tester.tap(find.byTooltip('Delete'));
      await tester.pump();
      expect(removes, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
