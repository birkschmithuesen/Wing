import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../models/attachment_draft.dart';
import 'attachment_image_preflight.dart';
import 'attachment_image_worker.dart';

/// Maximum number of mixed image/file drafts in a Remote Gateway composer.
const maxRemoteAttachmentDrafts = 40;

/// Aggregate Remote Gateway draft budget: exactly 128 MiB (134,217,728 bytes).
const maxRemoteAttachmentDraftBytes = 128 * 1024 * 1024;

/// Existing per-item limit for generic files: exactly 16 MiB.
const maxGenericAttachmentBytes = 16 * 1024 * 1024;

final _mediaTypePattern = RegExp(
  r'^[a-zA-Z0-9][a-zA-Z0-9!#$&^_.+-]*/[a-zA-Z0-9][a-zA-Z0-9!#$&^_.+-]*$',
);

String _safeMediaType(String value) {
  final normalized = value.trim().toLowerCase();
  return _mediaTypePattern.hasMatch(normalized)
      ? normalized
      : 'application/octet-stream';
}

typedef AttachmentCacheDirectoryProvider = Future<Directory> Function();
typedef AttachmentCacheFileWriter =
    Future<void> Function(File destination, List<int> bytes);
typedef AttachmentUploadCallback =
    Future<AttachmentUploadReceipt> Function({
      required AttachmentDraft draft,
      required String dataUrl,
    });
typedef AttachmentDraftChanged = FutureOr<void> Function(AttachmentDraft draft);
typedef AttachmentPromptSubmit = Future<void> Function(List<String> refTexts);

class AttachmentUploadReceipt {
  final String? refText;
  final String? imagePath;
  final String? attachedSessionId;
  final bool? atlasIntakeAccepted;

  const AttachmentUploadReceipt({
    this.refText,
    this.imagePath,
    this.attachedSessionId,
    this.atlasIntakeAccepted,
  });
}

/// Capability created only after validating the whole deletion-cleanup batch.
/// Paths are bound to the service's trusted app-managed cache directory.
class ValidatedAttachmentCleanup {
  ValidatedAttachmentCleanup._(this._root, this._files);
  final String? _root;
  final List<({String name, int bytes})> _files;
}

/// An immutable read capability for one app-managed image. Upload/error state
/// is not part of its identity, and it retains neither image bytes nor a Future.
final class AttachmentPreviewSource {
  AttachmentPreviewSource._(this._owner, AttachmentDraft draft)
    : _metadata = (
        id: draft.id,
        path: draft.cachedPath,
        bytes: draft.byteLength,
      ),
      _isImage = draft.isImage,
      _sanitized = draft.sanitized,
      _mediaType = draft.mediaType;

  final AttachmentDraftService _owner;
  final ({String id, String path, int bytes}) _metadata;
  final bool _isImage;
  final bool _sanitized;
  final String _mediaType;

  Future<Uint8List> readBytes() => _owner._readPreview(this);

  @override
  bool operator ==(Object other) =>
      other is AttachmentPreviewSource &&
      identical(_owner, other._owner) &&
      _metadata == other._metadata &&
      _isImage == other._isImage &&
      _sanitized == other._sanitized &&
      _mediaType == other._mediaType;

  @override
  int get hashCode => Object.hash(
    identityHashCode(_owner),
    _metadata,
    _isImage,
    _sanitized,
    _mediaType,
  );
}

class AttachmentDraftException implements Exception {
  final String message;

  const AttachmentDraftException(this.message);

  @override
  String toString() => message;
}

/// Testable boundary between ordered attachment upload and the single prompt
/// submission that follows it. Individual retry belongs to AttachmentDraftService.
class AttachmentDraftSendCoordinator {
  final AttachmentDraftService draftService;

  const AttachmentDraftSendCoordinator(this.draftService);

  Future<void> uploadThenSubmit({
    required Iterable<AttachmentDraft> drafts,
    required AttachmentUploadCallback upload,
    required AttachmentPromptSubmit submitPrompt,
    AttachmentDraftChanged? onChanged,
    bool removeCachedFileAfterUpload = true,
  }) async {
    final snapshot = drafts.toList(growable: false);
    await draftService.uploadSequential(
      drafts: snapshot,
      upload: upload,
      onChanged: onChanged,
      removeCachedFileAfterUpload: removeCachedFileAfterUpload,
    );
    final refs = snapshot
        .map((draft) => draft.refText)
        .whereType<String>()
        .where((ref) => ref.isNotEmpty)
        .toList(growable: false);
    if (snapshot.any((draft) => !draft.hasGatewayAttachment)) {
      throw const AttachmentDraftException(
        'Every attachment must have a gateway reference before prompt submit.',
      );
    }
    await submitPrompt(refs);
  }
}

/// Owns staged attachment I/O, image metadata sanitization, policy checks, and
/// sequential uploads. UI code only retains small [AttachmentDraft] records.
class AttachmentDraftService {
  final AttachmentCacheDirectoryProvider _cacheDirectoryProvider;
  final AttachmentCacheFileWriter _cacheFileWriter;
  final DateTime Function() _clock;
  int _sequence = 0;
  final _imageJobs = <AttachmentImageJob>{};

  AttachmentDraftService({
    AttachmentCacheDirectoryProvider? cacheDirectoryProvider,
    AttachmentCacheFileWriter? cacheFileWriter,
    DateTime Function()? clock,
  }) : _cacheDirectoryProvider =
           cacheDirectoryProvider ?? _defaultCacheDirectory,
       _cacheFileWriter = cacheFileWriter ?? _defaultCacheFileWriter,
       _clock = clock ?? DateTime.now;

  static Future<void> _defaultCacheFileWriter(
    File destination,
    List<int> bytes,
  ) async {
    await destination.writeAsBytes(bytes, flush: true);
  }

  static Future<Directory> _defaultCacheDirectory() async {
    final root = await getApplicationSupportDirectory();
    return Directory('${root.path}${Platform.pathSeparator}attachment_drafts');
  }

  /// Cancels CPU work and prevents an in-progress cache write from publishing.
  void cancelImagePreparations() {
    for (final job in _imageJobs.toList(growable: false)) {
      job.cancel();
    }
  }

  Future<AttachmentDraft> prepareImage({
    required String sourcePath,
    required String displayName,
    required Iterable<AttachmentDraft> existingDrafts,
    void Function(AttachmentImageJob)? onImageJob,
  }) => _prepareImage(
    displayName: displayName,
    existingDrafts: existingDrafts,
    onImageJob: onImageJob,
    start: (limit) => AttachmentImageWorker.shared.prepareFile(
      sourcePath,
      maxOutputBytes: limit,
    ),
  );

  Future<AttachmentDraft> prepareImageBytes({
    required Uint8List bytes,
    required String displayName,
    required Iterable<AttachmentDraft> existingDrafts,
    void Function(AttachmentImageJob)? onImageJob,
  }) => _prepareImage(
    displayName: displayName,
    existingDrafts: existingDrafts,
    onImageJob: onImageJob,
    start: (limit) =>
        AttachmentImageWorker.shared.prepareBytes(bytes, maxOutputBytes: limit),
  );

  Future<AttachmentDraft> _prepareImage({
    required String displayName,
    required Iterable<AttachmentDraft> existingDrafts,
    required AttachmentImageJob Function(int) start,
    void Function(AttachmentImageJob)? onImageJob,
  }) async {
    _ensureRemoteSlot(existingDrafts);
    File? destination;
    AttachmentImageJob? job;
    var committed = false;
    try {
      final current = existingDrafts.fold<int>(
        0,
        (sum, draft) => sum + draft.byteLength,
      );
      final remaining = maxRemoteAttachmentDraftBytes - current;
      final limit = remaining < maxAttachmentImageOutputBytes
          ? remaining
          : maxAttachmentImageOutputBytes;
      job = start(limit);
      _imageJobs.add(job);
      // Observe errors even if the owner's registration callback throws.
      job.result.ignore();
      onImageJob?.call(job);
      final output = await job.result;
      _ensureImageAuthority(job);
      _ensureRemoteAggregate(existingDrafts, output.bytes.length);
      final extension = output.isJpeg ? 'jpg' : 'png';
      destination = await _newCacheFile(extension);
      _ensureImageAuthority(job);
      await _cacheFileWriter(destination, output.bytes);
      _ensureImageAuthority(job);
      final outputStat = await destination.stat();
      _ensureImageAuthority(job);
      if (outputStat.type != FileSystemEntityType.file ||
          outputStat.size != output.bytes.length) {
        throw const AttachmentDraftException(
          'The prepared image could not be stored completely.',
        );
      }
      _ensureRemoteSlot(existingDrafts);
      _ensureRemoteAggregate(existingDrafts, outputStat.size);
      committed = true;
      return AttachmentDraft(
        id: _draftId(destination.path),
        cachedPath: destination.path,
        name: _replaceExtension(displayName, extension),
        byteLength: outputStat.size,
        mediaType: output.isJpeg ? 'image/jpeg' : 'image/png',
        kind: AttachmentDraftKind.image,
        sourceImageFormat: output.inspection.format,
        sanitized: true,
      );
    } on AttachmentImageException catch (error) {
      throw AttachmentDraftException(error.message);
    } on AttachmentDraftException {
      rethrow;
    } catch (_) {
      throw const AttachmentDraftException(
        'Unable to sanitize this image. Choose a valid JPEG, PNG, or WebP image.',
      );
    } finally {
      if (job != null) {
        if (!committed) job.cancel();
        _imageJobs.remove(job);
      }
      if (!committed && destination != null) {
        await _deleteIfPresent(destination);
      }
    }
  }

  void _ensureImageAuthority(AttachmentImageJob job) {
    if (job.isCancelled) {
      throw const AttachmentImageException('Image preparation was cancelled.');
    }
  }

  Future<AttachmentDraft> prepareGenericFile({
    required String sourcePath,
    required String displayName,
    String mediaType = 'application/octet-stream',
    required Iterable<AttachmentDraft> existingDrafts,
  }) async {
    _ensureRemoteSlot(existingDrafts);
    if (isSensitiveFileName(displayName)) {
      throw const AttachmentDraftException(
        'This filename is blocked because it may contain credentials.',
      );
    }
    final source = File(sourcePath);
    final stat = await source.stat();
    if (stat.type != FileSystemEntityType.file || stat.size <= 0) {
      throw const AttachmentDraftException(
        'The selected file is empty or unreadable.',
      );
    }
    if (stat.size > maxGenericAttachmentBytes) {
      throw const AttachmentDraftException(
        'Generic files are limited to 16 MiB each.',
      );
    }
    _ensureRemoteAggregate(existingDrafts, stat.size);

    final destination = await _newCacheFile('bin');
    try {
      await source.openRead().pipe(destination.openWrite());
      final copiedSize = await destination.length();
      if (copiedSize != stat.size) {
        throw const AttachmentDraftException(
          'The selected file could not be copied completely.',
        );
      }
      return AttachmentDraft(
        id: _draftId(destination.path),
        cachedPath: destination.path,
        name: displayName,
        byteLength: copiedSize,
        mediaType: _safeMediaType(mediaType),
        kind: AttachmentDraftKind.genericFile,
      );
    } catch (_) {
      await _deleteIfPresent(destination);
      rethrow;
    }
  }

  void validateRemoteDrafts(Iterable<AttachmentDraft> drafts) {
    final snapshot = drafts.toList(growable: false);
    if (snapshot.length > maxRemoteAttachmentDrafts) {
      throw const AttachmentDraftException(
        'You can attach up to 40 items to one Remote Gateway draft.',
      );
    }
    final total = snapshot.fold<int>(0, (sum, draft) => sum + draft.byteLength);
    if (total > maxRemoteAttachmentDraftBytes) {
      throw const AttachmentDraftException(
        'Attachments are limited to 128 MiB total per draft.',
      );
    }
    for (final draft in snapshot) {
      if (draft.kind == AttachmentDraftKind.genericFile &&
          draft.byteLength > maxGenericAttachmentBytes) {
        throw const AttachmentDraftException(
          'Generic files are limited to 16 MiB each.',
        );
      }
      if (draft.isImage && !draft.sanitized) {
        throw const AttachmentDraftException(
          'Remote images must be sanitized before upload.',
        );
      }
    }
  }

  Future<String> readDataUrl(AttachmentDraft draft) async {
    final bytes = await File(draft.cachedPath).readAsBytes();
    // The byte array is scoped to this one file and is never stored in the
    // draft model. The returned Base64 value is handed directly to transport.
    return 'data:${draft.mediaType};base64,${base64Encode(bytes)}';
  }

  AttachmentPreviewSource previewSource(AttachmentDraft draft) =>
      AttachmentPreviewSource._(this, draft);

  Future<Uint8List> _readPreview(AttachmentPreviewSource source) async {
    final metadata = source._metadata;
    if (!source._isImage ||
        !source._sanitized ||
        metadata.bytes <= 0 ||
        metadata.bytes > maxAttachmentImageOutputBytes ||
        (source._mediaType != 'image/jpeg' &&
            source._mediaType != 'image/png')) {
      throw const AttachmentDraftException(
        'This image preview is unavailable.',
      );
    }
    final managed = await _validateManagedFiles([metadata]);
    final root = managed._root!;
    final item = managed._files.single;
    if (!await _checkCleanupFile(root, item)) {
      throw const AttachmentDraftException(
        'This staged image is no longer available.',
      );
    }
    // Dart has no directory-handle-relative open. Revalidate after reading as
    // well; this does not claim an atomic filesystem identity guarantee.
    final file = await File(
      '$root${Platform.pathSeparator}${item.name}',
    ).open();
    late final Uint8List bytes;
    try {
      bytes = Uint8List(metadata.bytes);
      var offset = 0;
      while (offset < bytes.length) {
        final end = offset + 65536 < bytes.length
            ? offset + 65536
            : bytes.length;
        final count = await file.readInto(bytes, offset, end);
        if (count == 0) {
          throw const AttachmentDraftException(
            'The staged image changed while reading.',
          );
        }
        offset += count;
      }
      if (await file.readByte() != -1) {
        throw const AttachmentDraftException(
          'The staged image exceeds its declared size.',
        );
      }
    } finally {
      await file.close();
    }
    if (!await _checkCleanupFile(root, item)) {
      throw const AttachmentDraftException(
        'This staged image is no longer available.',
      );
    }
    try {
      final inspection = inspectAttachmentImage(bytes);
      if ((source._mediaType == 'image/jpeg' &&
              inspection.format != AttachmentImageFormat.jpeg) ||
          (source._mediaType == 'image/png' &&
              inspection.format != AttachmentImageFormat.png)) {
        throw const AttachmentDraftException(
          'The staged image format changed.',
        );
      }
    } on AttachmentImageException catch (error) {
      throw AttachmentDraftException(error.message);
    }
    return bytes;
  }

  Future<List<AttachmentUploadReceipt>> uploadSequential({
    required Iterable<AttachmentDraft> drafts,
    required AttachmentUploadCallback upload,
    AttachmentDraftChanged? onChanged,
    bool removeCachedFileAfterUpload = true,
  }) async {
    final snapshot = drafts.toList(growable: false);
    validateRemoteDrafts(snapshot);
    final receipts = <AttachmentUploadReceipt>[];
    for (final draft in snapshot) {
      if (draft.hasGatewayAttachment) {
        receipts.add(
          AttachmentUploadReceipt(
            refText: draft.refText,
            imagePath: draft.imagePath,
            attachedSessionId: draft.attachedSessionId,
            atlasIntakeAccepted: draft.atlasIntakeAccepted,
          ),
        );
        continue;
      }
      receipts.add(
        await _uploadOne(
          draft,
          upload: upload,
          onChanged: onChanged,
          removeCachedFileAfterUpload: removeCachedFileAfterUpload,
        ),
      );
    }
    return receipts;
  }

  Future<AttachmentUploadReceipt> _uploadOne(
    AttachmentDraft draft, {
    required AttachmentUploadCallback upload,
    AttachmentDraftChanged? onChanged,
    required bool removeCachedFileAfterUpload,
  }) async {
    draft
      ..status = AttachmentDraftStatus.uploading
      ..error = null;
    await onChanged?.call(draft);
    String? dataUrl;
    late AttachmentUploadReceipt receipt;
    try {
      dataUrl = await readDataUrl(draft);
      receipt = await upload(draft: draft, dataUrl: dataUrl);
    } catch (error) {
      dataUrl = null;
      draft
        ..status = AttachmentDraftStatus.failed
        ..error = error.toString();
      await onChanged?.call(draft);
      rethrow;
    }
    dataUrl = null;
    draft
      ..status = AttachmentDraftStatus.attached
      ..refText = receipt.refText
      ..imagePath = receipt.imagePath
      ..attachedSessionId = receipt.attachedSessionId
      ..atlasIntakeAccepted = receipt.atlasIntakeAccepted;
    await onChanged?.call(draft);
    // Images are queued on a live session. Keep their bytes until submit is
    // acknowledged so a replacement session can attach them again.
    if (removeCachedFileAfterUpload && !draft.isImage) {
      await removeCachedFile(draft);
    }
    return receipt;
  }

  Future<void> removeCachedFile(AttachmentDraft draft) async {
    await _deleteIfPresent(File(draft.cachedPath));
  }

  Future<void> removeAll(Iterable<AttachmentDraft> drafts) async {
    for (final draft in drafts) {
      await removeCachedFile(draft);
    }
  }

  /// Validate before clearing any draft. Persisted metadata alone never grants
  /// authority to delete arbitrary paths. Missing managed files are idempotent.
  Future<ValidatedAttachmentCleanup> validateDeletedDraftCleanup(
    Iterable<AttachmentDraft> drafts,
  ) => _validateManagedFiles([
    for (final draft in drafts)
      (id: draft.id, path: draft.cachedPath, bytes: draft.byteLength),
  ]);

  Future<ValidatedAttachmentCleanup> _validateManagedFiles(
    List<({String id, String path, int bytes})> captured,
  ) async {
    if (captured.isEmpty) return ValidatedAttachmentCleanup._(null, const []);
    final directory = await _cacheDirectoryProvider();
    final absoluteRoot = directory.absolute.path;
    final rootType = await FileSystemEntity.type(
      absoluteRoot,
      followLinks: false,
    );
    if (rootType != FileSystemEntityType.directory &&
        rootType != FileSystemEntityType.notFound) {
      throw const AttachmentDraftException(
        'Managed attachment cache is unavailable.',
      );
    }
    // A missing cache grants no arbitrary-path authority. Bind the absent leaf
    // to the existing trusted parent; never guess/create a replacement root.
    final parent = directory.absolute.parent;
    if (await FileSystemEntity.type(parent.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const AttachmentDraftException(
        'Managed attachment cache parent is unavailable.',
      );
    }
    final canonicalParent = await parent.resolveSymbolicLinks();
    final leaf = absoluteRoot.substring(
      absoluteRoot.lastIndexOf(Platform.pathSeparator) + 1,
    );
    final root = rootType == FileSystemEntityType.notFound
        ? '$canonicalParent${Platform.pathSeparator}$leaf'
        : await directory.resolveSymbolicLinks();
    final files = <({String name, int bytes})>[];
    for (final draft in captured) {
      final path = draft.path;
      final file = File(path);
      final name = path.substring(path.lastIndexOf(Platform.pathSeparator) + 1);
      if (path.length > 8192 ||
          path.contains('\u0000') ||
          path != file.absolute.path ||
          file.parent.path != absoluteRoot ||
          name != draft.id ||
          !RegExp(r'^draft-[0-9]+-[0-9]+\.(bin|jpg|png)$').hasMatch(name) ||
          draft.bytes <= 0 ||
          draft.bytes > maxRemoteAttachmentDraftBytes) {
        throw const AttachmentDraftException(
          'Invalid managed attachment cleanup metadata.',
        );
      }
      final item = (name: name, bytes: draft.bytes);
      await _checkCleanupFile(root, item);
      files.add(item);
    }
    return ValidatedAttachmentCleanup._(root, List.unmodifiable(files));
  }

  /// Strict completion: unlike accepted-upload housekeeping, I/O failures remain
  /// pending. Recheck symlinks immediately before removal; Dart does not expose
  /// an atomic directory-handle-relative unlink capability.
  Future<void> removeDeletedDraftCleanup(
    ValidatedAttachmentCleanup batch,
  ) async {
    final root = batch._root;
    if (root == null) return;
    for (final item in batch._files) {
      final rootType = await FileSystemEntity.type(root, followLinks: false);
      if (rootType == FileSystemEntityType.notFound) {
        final parent = Directory(root).parent;
        if (await FileSystemEntity.type(parent.path, followLinks: false) !=
                FileSystemEntityType.directory ||
            await parent.resolveSymbolicLinks() != parent.path) {
          throw const AttachmentDraftException(
            'Managed attachment cache parent changed.',
          );
        }
        return; // All validated direct children are absent; no unlink authority needed.
      }
      if (rootType != FileSystemEntityType.directory ||
          await Directory(root).resolveSymbolicLinks() != root) {
        throw const AttachmentDraftException(
          'Managed attachment cache changed.',
        );
      }
      final exists = await _checkCleanupFile(root, item);
      if (exists) {
        await File('$root${Platform.pathSeparator}${item.name}').delete();
      }
    }
  }

  Future<bool> _checkCleanupFile(
    String root,
    ({String name, int bytes}) item,
  ) async {
    final path = '$root${Platform.pathSeparator}${item.name}';
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.file ||
        await File(path).resolveSymbolicLinks() != path ||
        await File(path).length() != item.bytes) {
      throw const AttachmentDraftException('Managed attachment file changed.');
    }
    return true;
  }

  static bool isSensitiveFileName(String fileName) {
    final lower = fileName.trim().toLowerCase();
    if (lower.isEmpty) return true;
    if (lower == '.env' ||
        (lower.startsWith('.env.') &&
            !const {
              'dist',
              'example',
              'sample',
              'template',
            }.contains(lower.substring('.env.'.length)))) {
      return true;
    }
    if (lower == '.npmrc' || lower == '.netrc' || lower == '.pypirc') {
      return true;
    }
    if (lower.endsWith('.kdbx') ||
        lower.endsWith('.p12') ||
        lower.endsWith('.pem') ||
        lower.endsWith('.pfx')) {
      return true;
    }
    return RegExp(r'^id_(rsa|dsa|ecdsa|ed25519)(?:\..+)?$').hasMatch(lower);
  }

  void _ensureRemoteSlot(Iterable<AttachmentDraft> drafts) {
    if (drafts.length >= maxRemoteAttachmentDrafts) {
      throw const AttachmentDraftException(
        'You can attach up to 40 items to one Remote Gateway draft.',
      );
    }
  }

  void _ensureRemoteAggregate(
    Iterable<AttachmentDraft> drafts,
    int candidateBytes,
  ) {
    final current = drafts.fold<int>(0, (sum, draft) => sum + draft.byteLength);
    if (current + candidateBytes > maxRemoteAttachmentDraftBytes) {
      throw const AttachmentDraftException(
        'Attachments are limited to 128 MiB total per draft.',
      );
    }
  }

  Future<File> _newCacheFile(String extension) async {
    final directory = await _cacheDirectoryProvider();
    await directory.create(recursive: true);
    final id = '${_clock().microsecondsSinceEpoch}-${_sequence++}';
    return File(
      '${directory.path}${Platform.pathSeparator}draft-$id.$extension',
    );
  }

  String _draftId(String path) {
    final separator = Platform.pathSeparator;
    return path.substring(path.lastIndexOf(separator) + 1);
  }

  String _replaceExtension(String name, String extension) {
    final normalized = name.trim().isEmpty ? 'image' : name.trim();
    final dot = normalized.lastIndexOf('.');
    final base = dot > 0 ? normalized.substring(0, dot) : normalized;
    return '$base.$extension';
  }

  Future<void> _deleteIfPresent(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Upload state must not be rewound after the gateway accepted the file.
      // The app-private OS cache remains bounded by platform cache eviction.
    }
  }
}
