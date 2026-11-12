import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import '../models/skill_reader.dart';

typedef SkillReaderRead =
    Future<Map<String, dynamic>> Function(
      String endpoint,
      Map<String, String> query,
    );

/// Connection-local stock API reader. Fan-out is bounded and observations are
/// shared across skill routes; widgets never fetch or infer telemetry.
class SkillReaderRepository {
  SkillReaderRepository(this.read);
  final SkillReaderRead read;
  final _cache = <String, Future<Map<String, dynamic>>>{};
  DateTime? _capturedAt;
  Future<Map<String, dynamic>> _shared(
    String endpoint,
    Map<String, String> query,
  ) {
    if (_capturedAt == null ||
        DateTime.now().difference(_capturedAt!) > const Duration(minutes: 5)) {
      _cache.clear();
      _capturedAt = DateTime.now();
    }
    final key = '$endpoint?${Uri(queryParameters: query).query}';
    return _cache.putIfAbsent(key, () async {
      try {
        return await read(endpoint, query);
      } catch (_) {
        _cache.remove(key);
        rethrow;
      }
    });
  }

  List<Map> _entries(Map response) =>
      response['error'] == null && response['entries'] is List
      ? (response['entries'] as List).whereType<Map>().toList()
      : const [];
  Map? _child(Map response, String parent, String name, bool directory) =>
      _entries(response)
          .where(
            (e) =>
                e['name'] == name &&
                e['path'] == path.posix.join(parent, name) &&
                e['isDirectory'] == directory,
          )
          .firstOrNull;

  Future<SkillReaderObservation> load(
    SkillReaderTarget document,
    String profile, {
    bool Function()? isActive,
  }) async {
    String? category;
    List<SkillReference> references = [];
    List<SkillProfileActivity> activity = [];
    var discovered = 0;
    await Future.wait([
      (() async {
        try {
          final catalog = await _shared('skills', {'profile': profile});
          final rows = catalog['data'];
          if (rows is List) {
            final matches = rows
                .whereType<Map>()
                .where((r) => r['name'] == document.name)
                .toList();
            if (matches.length == 1) {
              final value = matches.single['category'];
              if (value is String && value.isNotEmpty) category = value;
            }
          }
        } catch (_) {
          /* Optional metadata does not invalidate the received document. */
        }
        final source = document.sourcePath;
        if (source == null || !path.posix.isAbsolute(source)) return;
        try {
          final parent = path.posix.dirname(source);
          final listing = await read('fs/list', {
            'path': parent,
            'profile': profile,
          });
          final folder = _child(listing, parent, 'references', true);
          if (folder == null) return;
          final pending = <String>[folder['path'] as String], seen = <String>{};
          while (pending.isNotEmpty &&
              seen.length < 64 &&
              isActive?.call() != false) {
            final directory = pending.removeLast();
            if (!seen.add(directory)) continue;
            final response = await read('fs/list', {
              'path': directory,
              'profile': profile,
            });
            for (final entry in _entries(response)) {
              final name = entry['name'], target = entry['path'];
              if (name is! String ||
                  target is! String ||
                  path.posix.basename(target) != name ||
                  path.posix.dirname(target) != directory) {
                continue;
              }
              if (entry['isDirectory'] == true) pending.add(target);
              if (entry['isDirectory'] == false) {
                references.add(
                  SkillReference(
                    name: name,
                    path: target,
                    bytes: entry['byteSize'] is int
                        ? entry['byteSize'] as int
                        : null,
                  ),
                );
              }
            }
          }
          references.sort((a, b) => a.path.compareTo(b.path));
        } catch (_) {
          /* Preserve successfully received listings without inventing files. */
        }
      })(),
      (() async {
        try {
          final discovery = await _shared('profiles', {}),
              profiles = discovery['profiles'];
          if (profiles is! List) return;
          final rows = profiles
              .whereType<Map>()
              .where((p) => p['name'] is String && p['path'] is String)
              .toList();
          discovered = rows.length;
          // Three profiles at a time, and cached endpoint reads once per connection.
          for (var i = 0; i < rows.length; i += 3) {
            if (isActive?.call() == false) break;
            final batch = rows.skip(i).take(3);
            final results = await Future.wait(
              batch.map((p) => _profileActivity(p, document.name)),
            );
            activity.addAll(results.whereType<SkillProfileActivity>());
          }
        } catch (_) {
          /* Unknown activity stays absent. */
        }
      })(),
    ]);
    return SkillReaderObservation(
      category: category,
      references: references,
      activity: activity,
      discoveredProfiles: discovered,
    );
  }

  Future<SkillProfileActivity?> _profileActivity(
    Map profile,
    String skill,
  ) async {
    final name = profile['name'] as String, home = profile['path'] as String;
    int? uses, patches, requests;
    DateTime? lastPatched;
    await Future.wait([
      (() async {
        try {
          final folder = _child(
            await _shared('fs/list', {'profile': name, 'path': home}),
            home,
            'skills',
            true,
          );
          if (folder == null) return;
          final directory = folder['path'] as String;
          final file = _child(
            await _shared('fs/list', {'profile': name, 'path': directory}),
            directory,
            '.usage.json',
            false,
          );
          if (file == null) return;
          final response = await _shared('fs/read-text', {
            'profile': name,
            'path': file['path'] as String,
          });
          if (response['binary'] != false ||
              response['truncated'] != false ||
              response['text'] is! String) {
            return;
          }
          final records = jsonDecode(response['text'] as String);
          if (records is! Map || records[skill] is! Map) return;
          final record = records[skill] as Map;
          uses = _count(record['use_count']);
          patches = _count(record['patch_count']);
          final date = record['last_patched_at'];
          if (date is String) lastPatched = DateTime.tryParse(date);
        } catch (_) {
          /* Malformed, incomplete and missing records are unknown. */
        }
      })(),
      (() async {
        try {
          final response = await _shared('analytics/usage', {
            'profile': name,
            'days': '90',
          });
          final skills = response['skills'];
          final rows = skills is Map ? skills['top_skills'] : null;
          if (rows is! List) return;
          final matches = rows
              .whereType<Map>()
              .where((r) => r['skill'] == skill)
              .toList();
          if (matches.length == 1) {
            requests = _count(matches.single['view_count']);
          }
        } catch (_) {
          /* Analytics absence does not mean zero requests. */
        }
      })(),
    ]);
    if (uses == null &&
        patches == null &&
        requests == null &&
        lastPatched == null) {
      return null;
    }
    return SkillProfileActivity(
      profile: name,
      uses: uses,
      patches: patches,
      lastPatched: lastPatched,
      readRequests: requests,
    );
  }

  Future<SkillReferenceContent> reference(
    SkillReference reference,
    String profile,
  ) async {
    final result = await read('fs/read-text', {
      'path': reference.path,
      'profile': profile,
    });
    if (result['binary'] != false ||
        result['text'] is! String ||
        result['path'] != reference.path ||
        result['truncated'] is! bool) {
      throw const FormatException('Reference text is unavailable.');
    }
    final markdown = {
      '.md',
      '.markdown',
    }.contains(path.posix.extension(reference.name).toLowerCase());
    return SkillReferenceContent(
      name: reference.name,
      content: result['text'] as String,
      path: reference.path,
      markdown: markdown,
      truncated: result['truncated'] as bool,
    );
  }
}

int? _count(Object? value) => value is int && value >= 0 ? value : null;

/// A viewer lease fences late reads and holds its captured connection alive.
class SkillReaderSession extends ChangeNotifier {
  SkillReaderSession({
    required this.repository,
    required this.document,
    required this.profile,
    void Function()? retain,
    this.release,
  }) {
    retain?.call();
  }
  final SkillReaderRepository repository;
  final SkillReaderTarget document;
  final String profile;
  final void Function()? release;
  SkillReaderObservation? _observation;
  SkillReaderObservation? get observation => _observation;
  bool _disposed = false;
  bool _released = false;
  int _generation = 0, _pending = 0;
  void _settled() {
    if (_disposed && _pending == 0 && !_released) {
      _released = true;
      release?.call();
    }
  }

  Future<void> load() async {
    if (_disposed) return;
    final generation = ++_generation;
    _pending++;
    try {
      final result = await repository.load(
        document,
        profile,
        isActive: () => !_disposed && generation == _generation,
      );
      if (_disposed || generation != _generation) return;
      _observation = result;
      notifyListeners();
    } finally {
      _pending--;
      _settled();
    }
  }

  Future<SkillReferenceContent> openReference(SkillReference reference) async {
    if (_disposed || _observation?.references.contains(reference) != true) {
      throw StateError('Reference no longer available.');
    }
    _pending++;
    try {
      final result = await repository.reference(reference, profile);
      if (_disposed) throw StateError('Skill viewer closed.');
      return result;
    } finally {
      _pending--;
      _settled();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _settled();
    super.dispose();
  }
}
