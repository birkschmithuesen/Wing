import 'attachment_draft.dart';

/// Current scoped REST observation; it is not an atomic revision precondition.
enum SessionPresence { absent, present, unavailable }

/// Prepared is deliberately uncertain after a restart or unsuccessful dispatch.
/// Only acknowledgement or an explicit owned absence observation permits cleanup.
enum DeletedDraftCleanupPhase { prepared, acknowledged, completed }

/// Immutable local file metadata. No draft text, upload reference or credentials
/// are journaled; the attachment owner continues to perform actual file removal.
class DeletedDraftFile {
  const DeletedDraftFile._({
    required this.id,
    required this.path,
    required this.name,
    required this.byteLength,
    required this.mediaType,
    required this.kind,
  });
  final String id;
  final String path;
  final String name;
  final int byteLength;
  final String mediaType;
  final AttachmentDraftKind kind;

  factory DeletedDraftFile.capture(AttachmentDraft file) =>
      DeletedDraftFile.fromJson({
        'id': file.id,
        'path': file.cachedPath,
        'name': file.name,
        'bytes': file.byteLength,
        'media_type': file.mediaType,
        'kind': file.kind.name,
      });

  factory DeletedDraftFile.fromJson(Map<String, dynamic> value) {
    final id = value['id'];
    final path = value['path'];
    final name = value['name'];
    final bytes = value['bytes'];
    final mediaType = value['media_type'];
    final kind = value['kind'];
    if (value.keys.toSet().difference(const {
          'id',
          'path',
          'name',
          'bytes',
          'media_type',
          'kind',
        }).isNotEmpty ||
        id is! String ||
        id.isEmpty ||
        path is! String ||
        path.isEmpty ||
        name is! String ||
        name.isEmpty ||
        bytes is! int ||
        bytes <= 0 ||
        mediaType is! String ||
        mediaType.isEmpty ||
        kind is! String ||
        !AttachmentDraftKind.values.any((k) => k.name == kind)) {
      throw const FormatException('Invalid deleted-draft file metadata');
    }
    return DeletedDraftFile._(
      id: id,
      path: path,
      name: name,
      byteLength: bytes,
      mediaType: mediaType,
      kind: AttachmentDraftKind.values.singleWhere((k) => k.name == kind),
    );
  }

  Map<String, Object> toJson() => {
    'id': id,
    'path': path,
    'name': name,
    'bytes': byteLength,
    'media_type': mediaType,
    'kind': kind.name,
  };

  AttachmentDraft attachment() => AttachmentDraft(
    id: id,
    cachedPath: path,
    name: name,
    byteLength: byteLength,
    mediaType: mediaType,
    kind: kind,
  );

  @override
  bool operator ==(Object other) =>
      other is DeletedDraftFile &&
      id == other.id &&
      path == other.path &&
      name == other.name &&
      byteLength == other.byteLength &&
      mediaType == other.mediaType &&
      kind == other.kind;
  @override
  int get hashCode => Object.hash(id, path, name, byteLength, mediaType, kind);
}

/// One captured profile/session receipt. Completed tombstones remain durable so
/// an older reading snapshot cannot restore a conversation after local cleanup.
class DeletedDraftCleanupReceipt {
  DeletedDraftCleanupReceipt({
    required this.profile,
    required this.session,
    required this.phase,
    required Iterable<DeletedDraftFile> files,
  }) : files = _uniqueFiles(files) {
    if (profile.isEmpty ||
        session.isEmpty ||
        phase == DeletedDraftCleanupPhase.completed && this.files.isNotEmpty) {
      throw const FormatException('Invalid deleted-draft receipt');
    }
  }
  final String profile;
  final String session;
  final DeletedDraftCleanupPhase phase;
  final List<DeletedDraftFile> files;
  bool get confirmed => phase != DeletedDraftCleanupPhase.prepared;

  DeletedDraftCleanupReceipt acknowledged(
    Iterable<DeletedDraftFile> additions,
  ) {
    return DeletedDraftCleanupReceipt(
      profile: profile,
      session: session,
      phase: DeletedDraftCleanupPhase.acknowledged,
      files: [...files, ...additions],
    );
  }

  static List<DeletedDraftFile> _uniqueFiles(Iterable<DeletedDraftFile> files) {
    final merged = <String, DeletedDraftFile>{};
    for (final file in files) {
      final previous = merged[file.path];
      if (previous != null && previous != file) {
        throw const FormatException('Conflicting deleted-draft file metadata');
      }
      merged[file.path] = file;
    }
    return List.unmodifiable(merged.values);
  }

  DeletedDraftCleanupReceipt completed() {
    if (!confirmed) throw StateError('Deletion is not confirmed');
    return DeletedDraftCleanupReceipt(
      profile: profile,
      session: session,
      phase: DeletedDraftCleanupPhase.completed,
      files: const [],
    );
  }
}
