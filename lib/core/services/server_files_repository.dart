import 'dart:typed_data';

import '../models/server_reference.dart';
import 'connection_manager.dart' show DashboardRequestNotSentException;

typedef ServerFilesRead =
    Future<Map<String, dynamic>> Function(
      String endpoint,
      Map<String, String> query,
    );
typedef ServerFilesWrite =
    Future<Map<String, dynamic>> Function(
      String endpoint,
      Map<String, dynamic> body,
      bool Function() canDispatch,
    );

/// Stock server-file transport, canonical path admission and confirmed writes.
/// Captured consumers own timing, cancellation and whole-workflow budgets.
final class ServerFilesRepository {
  const ServerFilesRepository({required this.read, required this.write});
  final ServerFilesRead read;
  final ServerFilesWrite? write;

  Future<String> defaultDirectory() async {
    final response = await read('fs/default-cwd', const {});
    final path = response['cwd'];
    if (path is! String) {
      throw const FormatException('Invalid profile default directory.');
    }
    ServerReferencePath.admit(path);
    return path;
  }

  Future<ServerReferenceDirectory> directory(String? requested) async {
    if (requested != null) ServerReferencePath.admit(requested);
    final response = await read('files', {'path': ?requested});
    final path = response['path'],
        parent = response['parent'],
        rows = response['entries'];
    if (path is! String ||
        rows is! List ||
        (parent != null && parent is! String)) {
      throw const FormatException('Invalid server directory.');
    }
    ServerReferencePath.admit(path);
    if (parent is String) ServerReferencePath.admit(parent);
    final entries = <ServerReferenceEntry>[];
    for (final row in rows) {
      if (row is! Map ||
          row['name'] is! String ||
          row['path'] is! String ||
          row['is_directory'] is! bool) {
        throw const FormatException('Invalid server entry.');
      }
      final name = row['name'] as String, target = row['path'] as String;
      if (name.isEmpty ||
          ServerReferencePath.pathContext.basename(name) != name ||
          name == '.' ||
          name == '..') {
        throw const FormatException('Invalid server name.');
      }
      try {
        ServerReferencePath.admit(target);
      } on FormatException {
        continue;
      }
      if (row['broken_link'] == true) continue;
      final dir = row['is_directory'] as bool;
      if (!dir &&
          (row['size'] is! int ||
              (row['size'] as int) < 0 ||
              row['mime_type'] is! String)) {
        throw const FormatException('Invalid server file metadata.');
      }
      entries.add(
        ServerReferenceEntry(
          name: name,
          path: target,
          directory: dir,
          size: dir ? null : row['size'] as int,
          mime: dir ? null : row['mime_type'] as String,
        ),
      );
    }
    return ServerReferenceDirectory(path, parent as String?, entries);
  }

  Future<ServerReferenceEntry> entry(
    String path, {
    bool canonical = true,
    bool folder = false,
  }) async {
    ServerReferencePath.admit(path);
    if (folder) {
      final listing = await directory(path);
      if (canonical && listing.path != path) {
        throw const FormatException('The selected folder changed. Retry.');
      }
      return ServerReferenceEntry(
        name: ServerReferencePath.pathContext.basename(listing.path),
        path: listing.path,
        directory: true,
        size: null,
        mime: null,
      );
    }
    final listing = await directory(
      ServerReferencePath.pathContext.dirname(path),
    );
    // Selection has already resolved aliases; a later alias to another target
    // is not the selected location. Never read before this canonical preflight.
    return listing.entries
            .where(
              (e) =>
                  (!canonical || e.path == path) &&
                  e.name == ServerReferencePath.pathContext.basename(path),
            )
            .firstOrNull ??
        (throw FormatException(
          '$path is unavailable. Edit the reference and retry.',
        ));
  }

  Future<Uint8List> bytes(
    ServerReferenceEntry entry, {
    required int maxBytes,
  }) async {
    ServerReferencePath.admit(entry.path);
    if (entry.directory || entry.size == null || entry.size! > maxBytes) {
      throw FormatException(
        '${entry.name} is too large to include. Edit the reference.',
      );
    }
    final response = await read('files/read', {'path': entry.path});
    final target = response['path'],
        size = response['size'],
        data = response['data_url'];
    if (target is! String) {
      throw const FormatException('Missing canonical read target.');
    }
    ServerReferencePath.admit(target);
    if (target != entry.path ||
        size is! int ||
        size < 0 ||
        size > maxBytes ||
        data is! String ||
        data.length > maxBytes * 2 + 256) {
      throw const FormatException(
        'The file changed or exceeded the read limit. Retry.',
      );
    }
    final uri = UriData.parse(data);
    if (!uri.isBase64) {
      throw const FormatException('Invalid server file encoding.');
    }
    final bytes = uri.contentAsBytes();
    if (bytes.length != size) {
      throw const FormatException('Incomplete server file read.');
    }
    return bytes;
  }

  Future<String> createDirectory(
    String path, {
    required bool Function() canDispatch,
  }) async {
    ServerReferencePath.admit(path);
    final send = write;
    if (send == null) throw StateError('Server file writes are unavailable');
    late final Map<String, dynamic> directory;
    try {
      directory = await send('files/mkdir', {'path': path}, canDispatch);
    } on DashboardRequestNotSentException {
      rethrow;
    } catch (_) {
      throw StateError(
        'Could not create the project folder. Check the path and permissions, then try again.',
      );
    }
    final folder = directory['path'];
    final entry = directory['entry'];
    if (directory['ok'] != true ||
        folder is! String ||
        folder.trim().isEmpty ||
        entry is! Map ||
        entry['is_directory'] != true ||
        entry['path'] != folder) {
      throw StateError(
        'Hermes did not confirm the project folder. Check the folder and try again.',
      );
    }
    ServerReferencePath.admit(folder);
    return folder;
  }
}
