enum ProfileCapabilityKind { skills, tools }

enum ProfileCapabilityGroup { needsSetup, enabled, disabled }

enum ProfileCapabilityFilter { all, enabled, needsSetup }

enum ProfileCapabilitiesOperation { idle, confirming, saving }

/// A detached observation of one stock skill or toolset; no response map escapes.
class ProfileCapability {
  final String name;
  final String title;
  final String description;
  final bool enabled;
  final bool? configured;
  final String? platform;
  final String? platformLabel;
  final String? category;
  final String? provenance;
  final List<String> tools;
  final bool hasTools;

  ProfileCapability({
    required this.name,
    required this.title,
    required this.description,
    required this.enabled,
    required this.configured,
    required this.platform,
    required this.platformLabel,
    required this.category,
    required this.provenance,
    required Iterable<String> tools,
    required this.hasTools,
  }) : tools = List.unmodifiable(tools);

  ProfileCapabilityGroup get group => !enabled
      ? ProfileCapabilityGroup.disabled
      : configured == false
      ? ProfileCapabilityGroup.needsSetup
      : ProfileCapabilityGroup.enabled;

  bool get needsEnableConfirmation => configured == false;

  String subtitle(ProfileCapabilityKind kind) =>
      kind == ProfileCapabilityKind.skills
      ? '${category ?? 'Skill'} · ${provenance ?? 'Installed'}'
      : '${enabled ? 'Enabled' : 'Off'} · ${configured == null
            ? 'Setup status unavailable'
            : configured!
            ? 'Configured'
            : 'Setup needed'}${platformLabel == null ? '' : ' · $platformLabel'}';

  bool matches(String query) =>
      '$name $title $description'.toLowerCase().contains(query.toLowerCase());

  bool matchesFilter(ProfileCapabilityFilter filter) => switch (filter) {
    ProfileCapabilityFilter.all => true,
    ProfileCapabilityFilter.enabled => enabled,
    ProfileCapabilityFilter.needsSetup => configured == false,
  };

  ProfileCapability withEnabled(bool value) => ProfileCapability(
    name: name,
    title: title,
    description: description,
    enabled: value,
    configured: configured,
    platform: platform,
    platformLabel: platformLabel,
    category: category,
    provenance: provenance,
    tools: tools,
    hasTools: hasTools,
  );

  static List<ProfileCapability> decode(
    Map<String, dynamic> response,
    ProfileCapabilityKind kind,
  ) {
    final data = response['data'];
    if (data is! List) throw const FormatException('Invalid capability list');
    final names = <String>{};
    final rows = <ProfileCapability>[];
    for (final value in data) {
      if (value is! Map ||
          value['name'] is! String ||
          (value['name'] as String).isEmpty ||
          !names.add(value['name'] as String) ||
          value['enabled'] is! bool ||
          (kind == ProfileCapabilityKind.tools &&
              value['configured'] is! bool)) {
        throw const FormatException('Invalid capability row');
      }
      String? text(String key) {
        final field = value[key];
        if (field != null && field is! String) {
          throw const FormatException('Invalid capability metadata');
        }
        return field as String?;
      }

      final tools = value['tools'];
      if (tools != null &&
          (tools is! List || tools.any((item) => item is! String))) {
        throw const FormatException('Invalid capability tools');
      }
      final name = value['name'] as String;
      rows.add(
        ProfileCapability(
          name: name,
          title: text('label') ?? name,
          description: text('description') ?? '',
          enabled: value['enabled'] as bool,
          configured: kind == ProfileCapabilityKind.tools
              ? value['configured'] as bool
              : null,
          platform: text('platform'),
          platformLabel: text('platform_label'),
          category: text('category'),
          provenance: text('provenance'),
          tools: tools == null ? const [] : tools.cast<String>(),
          hasTools: tools != null,
        ),
      );
    }
    if (kind == ProfileCapabilityKind.tools) {
      rows.sort((a, b) {
        final group = a.group.index.compareTo(b.group.index);
        return group == 0 ? a.title.compareTo(b.title) : group;
      });
    }
    return List.unmodifiable(rows);
  }
}

class ProfileSkillInstructions {
  final String name;
  final String content;
  const ProfileSkillInstructions({
    required this.name,
    required this.content,
    required this.sourcePath,
  });
  final String? sourcePath;
}

class ProfileCapabilitiesState {
  final ProfileCapabilityKind kind;
  final List<ProfileCapability> rows;
  final bool loading;
  final ProfileCapabilitiesOperation operation;
  final bool verified;
  final bool hasObservation;
  final String? error;
  final String? notice;

  ProfileCapabilitiesState({
    required this.hasObservation,
    required this.kind,
    required Iterable<ProfileCapability> rows,
    required this.loading,
    required this.operation,
    required this.verified,
    required this.error,
    required this.notice,
  }) : rows = List.unmodifiable(rows);

  bool get busy => operation != ProfileCapabilitiesOperation.idle;
  bool get saving => operation == ProfileCapabilitiesOperation.saving;
  bool get canToggle => verified && !loading && !busy;
}
