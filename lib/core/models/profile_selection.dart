import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'hermes_profile.dart';

enum ProfileSelectionValidity {
  absent,
  valid,
  invalid,
  unavailable,
  unverified,
}

enum ProfileSelectionSaveOutcome {
  saved,
  unchanged,
  failedRestored,
  failedUnverified,
  retired,
}

/// The sole current storage schema; absence is distinct from malformed data.
class ProfileSelectionCodec {
  static String storageKey(String connectionIdentity) {
    if (connectionIdentity.isEmpty) {
      throw ArgumentError('An exact connection identity is required');
    }
    return 'workspace_profile_selection_v1_${sha256.convert(utf8.encode(connectionIdentity))}';
  }

  static String? canonicalName(Object? value) =>
      value is String && HermesProfile.isCanonicalName(value) ? value : null;
}

@immutable
class ProfileSelectionFact {
  const ProfileSelectionFact({
    required this.validity,
    required this.confirmedName,
    required this.requestedName,
    required this.busy,
    required this.error,
  });

  final ProfileSelectionValidity validity;
  final String? confirmedName;
  final String? requestedName;
  final bool busy;
  final String? error;

  String? get selectedName =>
      validity == ProfileSelectionValidity.valid ? confirmedName : null;

  @override
  bool operator ==(Object other) =>
      other is ProfileSelectionFact &&
      validity == other.validity &&
      confirmedName == other.confirmedName &&
      requestedName == other.requestedName &&
      busy == other.busy &&
      error == other.error;

  @override
  int get hashCode =>
      Object.hash(validity, confirmedName, requestedName, busy, error);
}

@immutable
class ProfileSelectionSettlement {
  const ProfileSelectionSettlement(this.name, this.outcome);
  final String name;
  final ProfileSelectionSaveOutcome outcome;
  bool get confirmed =>
      outcome == ProfileSelectionSaveOutcome.saved ||
      outcome == ProfileSelectionSaveOutcome.unchanged;
}

/// Navigation can be admitted while an earlier persistence command is held.
/// The future always settles with typed facts, including failed physical writes.
class ProfileSelectionAdmission {
  const ProfileSelectionAdmission({
    required this.queuedBehindSelection,
    required this.settled,
  });
  final bool queuedBehindSelection;
  final Future<ProfileSelectionSettlement> settled;
}

class ProfileSelectionRepairRequired implements Exception {
  const ProfileSelectionRepairRequired(this.message);
  final String message;
}
