import 'dart:convert';

import 'package:path/path.dart' as paths;
import 'package:yaml/yaml.dart';

import '../models/profile_identity_edit.dart';
import 'connection_manager.dart';
import 'profiles_repository.dart';

typedef IdentityRead =
    Future<Map<String, dynamic>> Function(
      String endpoint,
      Map<String, String> query,
    );
typedef IdentityWrite =
    Future<Map<String, dynamic>> Function(
      String method,
      String endpoint,
      Map<String, String> query,
      Map<String, dynamic> body,
      bool Function() canDispatch,
      void Function() onDispatched,
    );

/// Stateless stock HTTP adapter. The edit session owns drafts and outcomes.
/// Managed host reads avoid the SSH-dependent fs/read-text namespace and the
/// profile RPC's unreadable-file-to-empty conversion. Stock has no revision CAS:
/// this preflight cannot exclude changes after a read or same-name recreation.
class ProfileIdentityRepository {
  const ProfileIdentityRepository({
    required this.name,
    required this.read,
    required this.write,
  });

  final String name;
  final IdentityRead read;
  final IdentityWrite write;
  static const _metadataLimit = 64 * 1024;
  static const _unavailable =
      'This field could not be read safely. Your edits are kept. Retry to check it.';
  static const _notSent = 'This change was not sent. Your edits are kept.';
  static const _uncertain =
      'This change could not be confirmed. Your edits are kept. Check the current text before saving again.';

  bool _validListing(List entries, paths.Context context) {
    final names = <String>{};
    for (final entry in entries) {
      if (entry is! Map) return false;
      final leaf = entry['name'];
      if (leaf is! String ||
          leaf.isEmpty ||
          leaf.length > 4096 ||
          leaf.contains('\u0000') ||
          leaf == '.' ||
          leaf == '..' ||
          context.basename(leaf) != leaf ||
          context.isAbsolute(leaf) ||
          !names.add(leaf)) {
        return false;
      }
    }
    return true;
  }

  Future<String> _profilePath() async {
    final roster = await read('profiles', const {});
    final discovery = await ProfilesRepository((endpoint) {
      return endpoint == 'profiles'
          ? Future.value(roster)
          : read(endpoint, const {});
    }).discover();
    if (discovery.named(name) == null) {
      throw const FormatException('The captured profile is unavailable');
    }
    final row = (roster['profiles'] as List).cast<Map>().singleWhere(
      (row) => row['name'] == name,
    );
    final path = row['path'];
    if (path is! String ||
        path.isEmpty ||
        path.length > 4096 ||
        path.contains('\u0000')) {
      throw const FormatException('Invalid profile directory');
    }
    final context = _pathContext(path);
    if (!context.isAbsolute(path) ||
        context.split(path).contains('..') ||
        context.normalize(path) != path) {
      throw const FormatException('Noncanonical profile directory');
    }
    return path;
  }

  paths.Context _pathContext(String path) => paths.Context(
    style: path.startsWith('/') ? paths.Style.posix : paths.Style.windows,
  );

  Future<String> _description(String directory) async {
    final metadataPath = _pathContext(
      directory,
    ).join(directory, 'profile.yaml');
    Map<String, dynamic> response;
    try {
      response = await read('files/read', {'path': metadataPath});
    } on DashboardHttpException catch (error) {
      if (error.statusCode != 404) rethrow;
      // A 404 may hide an inaccessible target; only a successful exact parent
      // listing with no metadata entry establishes observed absence.
      final listing = await read('files', {'path': directory});
      final entries = listing['entries'];
      if (listing['path'] != directory ||
          entries is! List ||
          !_validListing(entries, _pathContext(directory)) ||
          entries.any((entry) => (entry as Map)['name'] == 'profile.yaml')) {
        throw const FormatException('Metadata absence was not established');
      }
      return '';
    }
    final size = response['size'];
    final mime = response['mime_type'];
    final data = response['data_url'];
    if (response['name'] != 'profile.yaml' ||
        response['path'] != metadataPath ||
        size is! int ||
        size < 0 ||
        size > _metadataLimit ||
        mime is! String ||
        mime.isEmpty ||
        data is! String ||
        data.length > _metadataLimit * 2 ||
        !data.startsWith('data:$mime;base64,')) {
      throw const FormatException('Invalid metadata response');
    }
    final encoded = data.substring('data:$mime;base64,'.length);
    final bytes = base64.decode(encoded);
    if (bytes.length != size || base64.encode(bytes) != encoded) {
      throw const FormatException('Invalid metadata bytes');
    }
    final document = loadYaml(utf8.decode(bytes));
    if (document is! YamlMap || document.keys.any((key) => key is! String)) {
      throw const FormatException('Invalid profile metadata');
    }
    if (!document.containsKey('description')) return '';
    final description = document['description'];
    if (description is! String) {
      throw const FormatException('Invalid profile description');
    }
    return description.trim();
  }

  Future<String> _soul() async {
    final response = await read(
      'profiles/${Uri.encodeComponent(name)}/soul',
      const {},
    );
    final content = response['content'];
    final exists = response['exists'];
    if (content is! String ||
        exists is! bool ||
        !exists && content.isNotEmpty) {
      throw const FormatException('Invalid SOUL observation');
    }
    return content;
  }

  Future<ProfileIdentityObservation> load() async {
    final values = <ProfileIdentityField, String>{};
    final issues = <ProfileIdentityField, String>{};
    String directory;
    try {
      directory = await _profilePath();
    } catch (_) {
      return ProfileIdentityObservation(
        values: const {},
        issues: {
          for (final field in ProfileIdentityField.values) field: _unavailable,
        },
      );
    }
    for (final field in ProfileIdentityField.values) {
      try {
        values[field] = field == ProfileIdentityField.description
            ? await _description(directory)
            : await _soul();
      } catch (_) {
        issues[field] = _unavailable;
      }
    }
    return ProfileIdentityObservation(values: values, issues: issues);
  }

  Future<ProfileIdentitySaveResult> save(
    ProfileIdentityEditIntent intent, {
    required bool Function() canDispatch,
    required void Function(ProfileIdentityField) onDispatched,
  }) async {
    final results = <ProfileIdentityField, ProfileIdentityFieldResult>{};
    for (final field in ProfileIdentityField.values) {
      if (!intent.wanted.containsKey(field)) continue;
      var dispatched = false;
      var activeAttempt = true;
      bool active() => activeAttempt && canDispatch();
      try {
        if (!active()) throw const _Retired();
        final current = await load();
        if (!active()) throw const _Retired();
        final resolution = intent.resolve(current);
        if (resolution.issues.containsKey(field)) {
          results[field] = ProfileIdentityFieldResult.unavailable(
            resolution.issues[field]!,
          );
          continue;
        }
        if (resolution.conflicts.containsKey(field)) {
          results[field] = ProfileIdentityFieldResult.conflict(
            resolution.conflicts[field]!,
          );
          continue;
        }
        if (resolution.converged.containsKey(field)) {
          results[field] = ProfileIdentityFieldResult.converged(
            resolution.converged[field]!,
          );
          continue;
        }
        final wanted = resolution.updates[field]!;
        final response = await write(
          'PUT',
          'profiles/${Uri.encodeComponent(name)}/${field.name}',
          const {},
          {
            field == ProfileIdentityField.soul ? 'content' : 'description':
                wanted,
          },
          active,
          () {
            dispatched = true;
            onDispatched(field);
          },
        );
        if (response['ok'] != true ||
            field == ProfileIdentityField.description &&
                (response['description'] != wanted ||
                    response['description_auto'] != false)) {
          throw const FormatException('Invalid identity acknowledgement');
        }
        results[field] = ProfileIdentityFieldResult.confirmed(wanted);
      } catch (error) {
        results[field] = !dispatched
            ? const ProfileIdentityFieldResult.notSent(_notSent)
            : error is DashboardHttpException &&
                  {400, 401, 403, 404, 405, 422}.contains(error.statusCode)
            ? const ProfileIdentityFieldResult.rejected(
                'The server rejected this change. Your edits are kept.',
              )
            : const ProfileIdentityFieldResult.uncertain(_uncertain);
      } finally {
        // Timed-out authentication work loses authority before the next field.
        activeAttempt = false;
      }
    }
    return ProfileIdentitySaveResult(fields: results);
  }
}

class _Retired implements Exception {
  const _Retired();
}
