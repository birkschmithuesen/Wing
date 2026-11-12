/// Received resource identity; independent of document rendering.
final class SkillReaderTarget {
  const SkillReaderTarget({required this.name, this.sourcePath});
  final String name;
  final String? sourcePath;
}

final class SkillReferenceContent {
  const SkillReferenceContent({
    required this.name,
    required this.path,
    required this.content,
    required this.markdown,
    required this.truncated,
  });
  final String name, path, content;
  final bool markdown, truncated;
}

/// Optional, API-observed context for a received skill. Missing is never zero.
final class SkillProfileActivity {
  const SkillProfileActivity({
    required this.profile,
    this.uses,
    this.patches,
    this.lastPatched,
    this.readRequests,
  });
  final String profile;
  final int? uses, patches, readRequests;
  final DateTime? lastPatched;
}

final class SkillReference {
  const SkillReference({required this.name, required this.path, this.bytes});
  final String name, path;
  final int? bytes;
}

final class SkillReaderObservation {
  SkillReaderObservation({
    this.category,
    Iterable<SkillReference> references = const [],
    Iterable<SkillProfileActivity> activity = const [],
    this.discoveredProfiles = 0,
    this.readPeriodDays = 90,
  }) : references = List.unmodifiable(references),
       activity = List.unmodifiable(activity);
  final String? category;
  final List<SkillReference> references;
  final List<SkillProfileActivity> activity;
  final int discoveredProfiles, readPeriodDays;
  int? total(int? Function(SkillProfileActivity) value) {
    final observed = activity.map(value).whereType<int>().toList();
    return observed.isEmpty ? null : observed.fold<int>(0, (a, b) => a + b);
  }

  int? get uses => total((p) => p.uses);
  int? get patches => total((p) => p.patches);
  int? get readRequests => total((p) => p.readRequests);
  DateTime? get lastPatched {
    final dates =
        activity.map((p) => p.lastPatched).whereType<DateTime>().toList()
          ..sort();
    return dates.lastOrNull;
  }
}
