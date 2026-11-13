import 'provider_access.dart';

enum ProviderInventoryFilter {
  all('All'),
  stored('Stored'),
  attention('Needs attention');

  const ProviderInventoryFilter(this.label);
  final String label;
}

/// Passive identity for the current stock device-code route, never a credential.
class ProviderSignInTarget {
  const ProviderSignInTarget({required this.id, required this.name});
  final String id, name;
  factory ProviderSignInTarget.fromAccess(ProviderAccess access) {
    if (access.row['flow'] != 'device_code' || access.id.isEmpty) {
      throw const FormatException('Unsupported provider sign-in');
    }
    return ProviderSignInTarget(id: access.id, name: access.name);
  }
}

String providerInventoryStatus(ProviderAccess access) => switch (access.state) {
  ProviderAccessState.connected => 'Credentials detected',
  ProviderAccessState.expired => 'Access token expired',
  ProviderAccessState.signedOut => 'No sign-in stored',
  ProviderAccessState.external => 'Check external sign-in',
  ProviderAccessState.unknown => 'Status unavailable',
};

class ProviderInventoryEntry {
  ProviderInventoryEntry(ProviderAccess access)
    : id = access.id,
      name = access.name,
      state = access.state,
      statusLabel = providerInventoryStatus(access),
      sourceLabel = access.external
          ? 'Managed externally'
          : access.status['source_label'] is String
          ? access.status['source_label'] as String
          : 'Source not reported',
      expiresAt = access.expiresAt,
      hasCredential = access.hasCredential,
      sortOrder = access.sortOrder,
      signIn = access.row['flow'] == 'device_code'
          ? ProviderSignInTarget.fromAccess(access)
          : null;
  final String id, name, statusLabel, sourceLabel;
  final ProviderAccessState state;
  final DateTime? expiresAt;
  final bool hasCredential;
  final int sortOrder;
  final ProviderSignInTarget? signIn;
  bool get needsAttention =>
      state == ProviderAccessState.expired ||
      state == ProviderAccessState.unknown;
  bool get canSignInAgain =>
      state == ProviderAccessState.expired && signIn != null;
  String get expiryPrefix =>
      state == ProviderAccessState.expired ? 'Expired' : 'Expires';
  bool matches(String query, ProviderInventoryFilter filter) =>
      '$name $id $sourceLabel'.toLowerCase().contains(query.toLowerCase()) &&
      switch (filter) {
        ProviderInventoryFilter.all => true,
        ProviderInventoryFilter.stored =>
          state == ProviderAccessState.connected,
        ProviderInventoryFilter.attention => needsAttention,
      };
}

/// Whitelisted env metadata. Secret values/previews never enter this value.
class ProviderEnvironmentField {
  const ProviderEnvironmentField({
    required this.key,
    required this.label,
    required this.isSet,
    required this.managed,
    required this.category,
  });
  final String key, label, category;
  final bool isSet, managed;
  bool get editable => !managed && category != 'custom';
  bool matches(String query, {required bool catalog}) =>
      editable &&
      (catalog || query.isNotEmpty || isSet) &&
      '$key $label'.toLowerCase().contains(query.toLowerCase());
  factory ProviderEnvironmentField.fromWire(String key, Object? value) {
    if (key.isEmpty ||
        value is! Map ||
        value['is_set'] is! bool ||
        value['channel_managed'] is! bool ||
        value['category'] is! String ||
        value['provider_label'] is! String) {
      throw const FormatException('Invalid environment metadata');
    }
    final label = value['provider_label'] as String;
    return ProviderEnvironmentField(
      key: key,
      label: label.isEmpty ? key : label,
      isSet: value['is_set'] as bool,
      managed: value['channel_managed'] as bool,
      category: value['category'] as String,
    );
  }
  static List<ProviderEnvironmentField> fromResponse(
    Map<String, dynamic> data,
  ) => List.unmodifiable(
    data.entries.map(
      (entry) => ProviderEnvironmentField.fromWire(entry.key, entry.value),
    ),
  );
}

class ProviderInventory {
  ProviderInventory({
    required Iterable<ProviderInventoryEntry> providers,
    required Iterable<ProviderEnvironmentField> keys,
    required this.selectionsAvailable,
    required this.checkedAt,
  }) : providers = List.unmodifiable(providers),
       keys = List.unmodifiable(keys);
  final List<ProviderInventoryEntry> providers;
  final List<ProviderEnvironmentField> keys;
  final bool selectionsAvailable;
  final DateTime checkedAt;
  int count(ProviderInventoryFilter filter) => switch (filter) {
    ProviderInventoryFilter.all => providers.length,
    ProviderInventoryFilter.stored =>
      providers.where((p) => p.state == ProviderAccessState.connected).length,
    ProviderInventoryFilter.attention =>
      providers.where((p) => p.needsAttention).length,
  };
}
