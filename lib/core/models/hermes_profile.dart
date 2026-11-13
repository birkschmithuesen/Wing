import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

/// A profile exposed by a modern Hermes server.
///
/// [name] is the canonical routing identity. [displayName] is presentation
/// only and must never be sent back to the server in its place.
@immutable
class HermesProfile {
  static final RegExp _canonicalName = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

  final String name;
  final String displayName;
  final bool isDefault;
  final String? description;
  final String? provider;
  final String? model;

  const HermesProfile({
    required this.name,
    this.displayName = '',
    this.isDefault = false,
    this.description,
    this.provider,
    this.model,
  }) : assert(name != '');

  String get label => displayName.trim().isEmpty ? name : displayName.trim();

  /// Desktop's initial rail order: default first, then canonical profile names.
  /// Presentation-only renames must not move the default profile.
  static int compareForDisplay(HermesProfile a, HermesProfile b) {
    if (a.name == 'default' && b.name != 'default') return -1;
    if (b.name == 'default' && a.name != 'default') return 1;
    return a.name.compareTo(b.name);
  }

  static bool isCanonicalName(String value) => _canonicalName.hasMatch(value);

  factory HermesProfile.fromJson(Map<String, dynamic> json) {
    final rawName = json['name'];
    if (rawName is! String || !isCanonicalName(rawName)) {
      throw const FormatException('Profile has an invalid canonical name.');
    }

    String optionalString(String key) {
      final value = json[key];
      if (value == null) return '';
      if (value is! String) {
        throw FormatException('Profile $rawName has an invalid $key.');
      }
      return value;
    }

    final rawDefault = json['is_default'];
    if (rawDefault != null && rawDefault is! bool) {
      throw FormatException('Profile $rawName has an invalid is_default.');
    }

    final description = optionalString('description').trim();
    final provider = optionalString('provider').trim();
    final model = optionalString('model').trim();
    return HermesProfile(
      name: rawName,
      displayName: optionalString('display_name'),
      isDefault: rawDefault == true,
      description: description.isEmpty ? null : description,
      provider: provider.isEmpty ? null : provider,
      model: model.isEmpty ? null : model,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HermesProfile &&
          name == other.name &&
          displayName == other.displayName &&
          isDefault == other.isDefault &&
          description == other.description &&
          provider == other.provider &&
          model == other.model;

  @override
  int get hashCode =>
      Object.hash(name, displayName, isDefault, description, provider, model);
}

/// The minimum identity for profile-owned Workspace state.
@immutable
class WorkspaceScope {
  final String connectionId;
  final String profileName;

  /// Opaque endpoint/authentication identity. Empty scopes are suitable for
  /// discovery only, never persisted chat ownership.
  final String connectionIdentity;

  WorkspaceScope({
    required this.connectionId,
    required this.profileName,
    this.connectionIdentity = '',
  }) {
    if (connectionId.trim().isEmpty) {
      throw ArgumentError.value(
        connectionId,
        'connectionId',
        'must not be empty',
      );
    }
    if (!HermesProfile.isCanonicalName(profileName)) {
      throw ArgumentError.value(
        profileName,
        'profileName',
        'must be a canonical Hermes profile name',
      );
    }
  }

  /// Stable, path-safe identity for preferences, caches, and durable state.
  ///
  /// The unhashed values remain available as typed fields; user-controlled
  /// names never become raw path or preference-key segments.
  String get storageNamespace => sha256
      .convert(
        utf8.encode('$connectionId\u0000$connectionIdentity\u0000$profileName'),
      )
      .toString();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkspaceScope &&
          connectionId == other.connectionId &&
          connectionIdentity == other.connectionIdentity &&
          profileName == other.profileName;

  @override
  int get hashCode =>
      Object.hash(connectionId, connectionIdentity, profileName);
}
