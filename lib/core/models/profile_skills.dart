import 'dart:convert';
import 'package:crypto/crypto.dart';

final class InstalledSkill {
  const InstalledSkill(
    this.name,
    this.description,
    this.provenance,
    this.usage, {
    required this.locked,
  });
  final String name, description, provenance;
  final int usage;
  final bool locked;
  bool get editable => provenance == 'agent' && !name.startsWith('memory:');
  bool get uninstallable => provenance == 'hub';
  bool matches(String query) =>
      '$name $description'.toLowerCase().contains(query.toLowerCase());

  static List<InstalledSkill> decode(Map<String, dynamic> response) {
    final rows = response['data'];
    if (rows is! List) throw const FormatException('Invalid skill library');
    final names = <String>{};
    return List.unmodifiable([
      for (final row in rows)
        if (row is Map &&
            row['usage'] is int &&
            row['enabled'] is bool &&
            row['locked'] is bool &&
            names.add(_text(row, 'name')))
          InstalledSkill(
            _text(row, 'name'),
            _text(row, 'description', empty: true),
            _text(row, 'provenance'),
            row['usage'] as int,
            locked: row['locked'] as bool,
          )
        else
          throw const FormatException('Invalid installed skill'),
    ]);
  }
}

final class HubSkill {
  const HubSkill(this.name, this.description, this.source, this.identifier);
  final String name, description, source, identifier;
  static List<HubSkill> decode(
    Map<String, dynamic> response, {
    required bool searching,
  }) {
    final rows = response[searching ? 'results' : 'skills'];
    if (rows is! List) throw const FormatException('Invalid skill catalog');
    final ids = <String>{};
    return List.unmodifiable([
      for (final row in rows)
        if (row is Map && ids.add(_text(row, 'identifier')))
          HubSkill(
            _text(row, 'name'),
            _text(row, 'description', empty: true),
            _text(row, 'source', empty: true),
            _text(row, 'identifier'),
          )
        else
          throw const FormatException('Invalid catalog skill'),
    ]);
  }
}

final class SkillInstructions {
  const SkillInstructions(this.name, this.content, this.sourcePath);
  final String name, content;
  final String? sourcePath;
  static SkillInstructions decode(Map<String, dynamic> response, String name) {
    if (response['name'] != name || response['content'] is! String) {
      throw const FormatException('Invalid skill instructions');
    }
    return SkillInstructions(
      name,
      response['content'] as String,
      response['path'] is String ? response['path'] as String : null,
    );
  }
}

final class SkillPreview {
  const SkillPreview(this.name, this.source, this.trust, this.content);
  final String name, source, trust, content;
  static SkillPreview decode(Map<String, dynamic> response, String identifier) {
    if (response['identifier'] != identifier) {
      throw const FormatException(
        'Skill preview belongs to another catalog entry',
      );
    }
    return SkillPreview(
      _text(response, 'name'),
      _text(response, 'source', empty: true),
      _text(response, 'trust_level'),
      _text(response, 'skill_md', empty: true),
    );
  }
}

/// Issued identities name borrowed child routes. The owner checks object identity.
final class SkillDetailRoute {
  SkillDetailRoute(this.skill);
  final InstalledSkill skill;
}

final class SkillPreviewRoute {
  SkillPreviewRoute(this.skill);
  final HubSkill skill;
}

final class SkillEditorRoute {
  SkillEditorRoute(this.name, this.initial);
  final String name, initial;
}

final class SkillEditObservation {
  const SkillEditObservation(this.saved, this.draft, this.closeGranted);
  final String saved, draft;
  final bool closeGranted;
  bool get dirty => saved != draft;
  String? get validationError => draft.startsWith('\uFEFF')
      ? 'Remove the leading byte-order mark. Hermes omits it when reading instructions.'
      : draft.trim().isEmpty
      ? 'Instructions cannot be empty.'
      : null;
}

enum SkillsPhase { idle, reading, confirming, saving, result }

final class ProfileSkillsState {
  ProfileSkillsState({
    required Iterable<InstalledSkill> installed,
    required Iterable<HubSkill> catalog,
    required this.instructions,
    required this.preview,
    required this.edit,
    required this.phase,
    required this.verified,
    required this.hasObservation,
    required this.partial,
    required this.reviewRequired,
    required this.error,
    required this.notice,
  }) : installed = List.unmodifiable(installed),
       catalog = List.unmodifiable(catalog);
  final List<InstalledSkill> installed;
  final List<HubSkill> catalog;
  final SkillInstructions? instructions;
  final SkillPreview? preview;
  final SkillEditObservation? edit;
  final SkillsPhase phase;
  final bool verified, hasObservation, partial, reviewRequired;
  final String? error, notice;
  bool get busy => phase != SkillsPhase.idle;
  bool get saving => phase == SkillsPhase.saving;
  bool get canMutate => !busy && verified && !reviewRequired;
  bool get canSave =>
      canMutate && edit?.dirty == true && edit?.validationError == null;
  bool get canPopEditor =>
      edit?.closeGranted == true || !busy && edit?.dirty == false;
}

String skillHubActionName(String verb, String key) {
  final normalized = key.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-');
  final trimmed = normalized.replaceAll(RegExp(r'^-+|-+$'), '');
  final slug = trimmed.isEmpty
      ? 'skill'
      : trimmed.substring(0, trimmed.length > 48 ? 48 : trimmed.length);
  return 'skills-$verb-$slug-${sha1.convert(utf8.encode(key)).toString().substring(0, 8)}';
}

String _text(Map row, String key, {bool empty = false}) {
  final value = row[key];
  if (value is! String || !empty && value.isEmpty) {
    throw const FormatException('Invalid skill metadata');
  }
  return value;
}
