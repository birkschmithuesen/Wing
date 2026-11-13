/// The two independent replacement fields supported by stock profile identity.
enum ProfileIdentityField { description, soul }

String normalizeProfileIdentityText(ProfileIdentityField field, String value) =>
    field == ProfileIdentityField.description ? value.trim() : value;

String? validateProfileIdentityText(ProfileIdentityField field, String value) =>
    field == ProfileIdentityField.soul && value.startsWith('\uFEFF')
    ? 'SOUL starts with a byte-order mark that the server removes when reading. Remove that character before saving.'
    : null;

/// Available values and explicit failures are separate; failed reads are never
/// converted to empty replacement text. Both fields always have a disposition.
class ProfileIdentityObservation {
  ProfileIdentityObservation({
    required Map<ProfileIdentityField, String> values,
    required Map<ProfileIdentityField, String> issues,
  }) : values = Map.unmodifiable({
         for (final entry in values.entries)
           entry.key: normalizeProfileIdentityText(entry.key, entry.value),
       }),
       issues = Map.unmodifiable(issues) {
    if (values.keys.any(issues.containsKey) ||
        {...values.keys, ...issues.keys}.length !=
            ProfileIdentityField.values.length ||
        issues.values.any((value) => value.trim().isEmpty)) {
      throw ArgumentError(
        'Identity fields need one available or failed observation',
      );
    }
  }
  final Map<ProfileIdentityField, String> values;
  final Map<ProfileIdentityField, String> issues;
}

/// Captured opening values plus user-changed fields. Description follows the
/// stock trim contract; SOUL retains exact text. This is the sole conflict and
/// sparse-update policy, used after fresh reads immediately before owned PUTs.
class ProfileIdentityEditIntent {
  ProfileIdentityEditIntent({
    required Map<ProfileIdentityField, String> baseline,
    required Map<ProfileIdentityField, String> wanted,
  }) : baseline = Map.unmodifiable({
         for (final entry in baseline.entries)
           entry.key: normalizeProfileIdentityText(entry.key, entry.value),
       }),
       wanted = Map.unmodifiable({
         for (final entry in wanted.entries)
           if (!baseline.containsKey(entry.key) ||
               normalizeProfileIdentityText(entry.key, entry.value) !=
                   normalizeProfileIdentityText(
                     entry.key,
                     baseline[entry.key]!,
                   ))
             entry.key: normalizeProfileIdentityText(entry.key, entry.value),
       }) {
    if (wanted.keys.any((field) => !baseline.containsKey(field))) {
      throw ArgumentError('An edit requires an available opening value');
    }
  }
  final Map<ProfileIdentityField, String> baseline, wanted;

  ProfileIdentityEditResolution resolve(ProfileIdentityObservation current) {
    final updates = <ProfileIdentityField, String>{};
    final converged = <ProfileIdentityField, String>{};
    final conflicts = <ProfileIdentityField, String>{};
    final issues = <ProfileIdentityField, String>{};
    for (final entry in wanted.entries) {
      final invalid = validateProfileIdentityText(entry.key, entry.value);
      if (invalid != null) {
        issues[entry.key] = invalid;
        continue;
      }
      final value = current.values[entry.key];
      if (value == null) {
        issues[entry.key] = current.issues[entry.key]!;
      } else if (value == entry.value) {
        converged[entry.key] = value;
      } else if (value != baseline[entry.key]) {
        conflicts[entry.key] = value;
      } else {
        updates[entry.key] = entry.value;
      }
    }
    return ProfileIdentityEditResolution(
      updates: updates,
      converged: converged,
      conflicts: conflicts,
      issues: issues,
    );
  }
}

class ProfileIdentityEditResolution {
  ProfileIdentityEditResolution({
    required Map<ProfileIdentityField, String> updates,
    required Map<ProfileIdentityField, String> converged,
    required Map<ProfileIdentityField, String> conflicts,
    required Map<ProfileIdentityField, String> issues,
  }) : updates = Map.unmodifiable(updates),
       converged = Map.unmodifiable(converged),
       conflicts = Map.unmodifiable(conflicts),
       issues = Map.unmodifiable(issues);
  final Map<ProfileIdentityField, String> updates, converged, conflicts, issues;
}

enum ProfileIdentityWriteDisposition {
  confirmed,
  converged,
  conflict,
  unavailable,
  notSent,
  rejected,
  uncertain,
}

/// A confirmed ACK remains confirmed even when a later observation fails.
/// Convergence establishes current text, not delivery of an earlier request.
class ProfileIdentityFieldResult {
  const ProfileIdentityFieldResult.confirmed(String text)
    : disposition = ProfileIdentityWriteDisposition.confirmed,
      value = text,
      issue = null;
  const ProfileIdentityFieldResult.converged(String text)
    : disposition = ProfileIdentityWriteDisposition.converged,
      value = text,
      issue = null;
  const ProfileIdentityFieldResult.conflict(String text)
    : disposition = ProfileIdentityWriteDisposition.conflict,
      value = text,
      issue = null;
  const ProfileIdentityFieldResult.unavailable(String message)
    : disposition = ProfileIdentityWriteDisposition.unavailable,
      value = null,
      issue = message;
  const ProfileIdentityFieldResult.notSent(String message)
    : disposition = ProfileIdentityWriteDisposition.notSent,
      value = null,
      issue = message;
  const ProfileIdentityFieldResult.rejected(String message)
    : disposition = ProfileIdentityWriteDisposition.rejected,
      value = null,
      issue = message;
  const ProfileIdentityFieldResult.uncertain(String message)
    : disposition = ProfileIdentityWriteDisposition.uncertain,
      value = null,
      issue = message;
  final ProfileIdentityWriteDisposition disposition;
  final String? value, issue;
}

class ProfileIdentitySaveResult {
  ProfileIdentitySaveResult({
    required Map<ProfileIdentityField, ProfileIdentityFieldResult> fields,
  }) : fields = Map.unmodifiable(fields);
  final Map<ProfileIdentityField, ProfileIdentityFieldResult> fields;
  bool get hasConfirmedChanges => fields.values.any(
    (value) => value.disposition == ProfileIdentityWriteDisposition.confirmed,
  );
}
