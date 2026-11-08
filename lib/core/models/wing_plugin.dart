import 'hermes_profile.dart';
import 'profile_plugins.dart';

/// Wing publishes stable, three-component release versions.
final class WingPluginVersion implements Comparable<WingPluginVersion> {
  WingPluginVersion._(this.value, this.parts);
  final String value;
  final List<int> parts;
  static WingPluginVersion? parse(String value) {
    if (!RegExp(
      r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$',
    ).hasMatch(value)) {
      return null;
    }
    return WingPluginVersion._(value, value.split('.').map(int.parse).toList());
  }

  @override
  int compareTo(WingPluginVersion other) {
    for (var i = 0; i < parts.length; i++) {
      final difference = parts[i].compareTo(other.parts[i]);
      if (difference != 0) return difference;
    }
    return 0;
  }
}

final class WingPluginRelease {
  const WingPluginRelease(this.version, this.commitSha);
  static const repository = 'https://github.com/tarkilhk/wing-hermes-plugin';
  final WingPluginVersion version;
  final String commitSha;
  factory WingPluginRelease.decode(Object? value) {
    if (value is! Map ||
        value['draft'] != false ||
        value['prerelease'] != false) {
      throw const FormatException('Invalid Wing release');
    }
    final tag = value['tag_name'];
    final version = tag is String && tag.startsWith('v')
        ? WingPluginVersion.parse(tag.substring(1))
        : null;
    if (version == null) {
      throw const FormatException('Invalid Wing release version');
    }
    final sha = value['target_commitish'];
    if (sha is! String || !RegExp(r'^[0-9a-f]{40}$').hasMatch(sha)) {
      throw const FormatException('Wing release must name an exact commit');
    }
    return WingPluginRelease(version, sha);
  }
  bool needsUpdate(ProfilePlugin plugin) {
    final installed = WingPluginVersion.parse(plugin.version);
    return installed == null || installed.compareTo(version) < 0;
  }
}

final class WingPluginProfile {
  const WingPluginProfile({
    required this.profile,
    this.plugin,
    this.observed = false,
    this.error,
    this.result,
  });
  final HermesProfile profile;
  final ProfilePlugin? plugin;
  final bool observed;
  final String? error, result;
  String get installedLabel => !observed
      ? 'Version unavailable'
      : plugin == null
      ? 'Not installed'
      : 'Version ${plugin!.version.isEmpty ? 'unknown' : plugin!.version} · ${plugin!.status.label}';
}

/// One projection for the settings card and plugin manager.
final class WingPluginOverview {
  const WingPluginOverview(
    this.title,
    this.detail,
    this.summary,
    this.installedVersions, {
    this.needsAttention = false,
  });
  final String title, detail, summary;
  final String? installedVersions;
  final bool needsAttention;

  factory WingPluginOverview.fromProfiles(
    List<WingPluginProfile> rows,
    WingPluginRelease? release, {
    required bool checking,
    required bool updating,
    required bool unavailable,
  }) {
    final versions =
        rows
            .where((row) => row.observed && row.plugin != null)
            .map(
              (row) =>
                  row.plugin!.version.isEmpty ? 'Unknown' : row.plugin!.version,
            )
            .toSet()
            .toList()
          ..sort((a, b) {
            final first = WingPluginVersion.parse(a),
                second = WingPluginVersion.parse(b);
            return first != null && second != null
                ? first.compareTo(second)
                : a.compareTo(b);
          });
    final installed = versions.isEmpty ? null : versions.join(' · ');
    var ready = 0,
        missing = 0,
        older = 0,
        pinned = 0,
        disabled = 0,
        unknown = 0,
        failed = 0;
    for (final row in rows) {
      if (row.error != null) {
        failed++;
      } else if (!row.observed) {
        unknown++;
      } else if (row.plugin == null) {
        missing++;
      } else if (release == null) {
        unknown++;
      } else if (release.needsUpdate(row.plugin!)) {
        if (row.plugin!.pinnedSha?.isNotEmpty == true) {
          pinned++;
        } else {
          older++;
        }
      } else if (!row.plugin!.enabled) {
        disabled++;
      } else {
        ready++;
      }
    }
    final counts = [
      if (ready > 0) '$ready ready',
      if (older > 0) '$older older',
      if (pinned > 0) '$pinned pinned',
      if (missing > 0) '$missing missing',
      if (disabled > 0) '$disabled disabled',
      if (unknown > 0) '$unknown unavailable',
      if (failed > 0) '$failed failed',
    ].join(' · ');
    if (updating) {
      return WingPluginOverview(
        'Installing or updating Wing…',
        'Results appear in Profiles as each operation finishes.',
        counts,
        installed,
      );
    }
    if (checking && (rows.isEmpty || unknown > 0)) {
      return WingPluginOverview(
        'Checking versions…',
        'Reading the plugin inventory for this server.',
        'Checking versions…',
        installed,
      );
    }
    if (unavailable || unknown > 0) {
      return WingPluginOverview(
        'Could not check versions',
        'Refresh to check before installing or updating.',
        'Version unavailable',
        installed,
        needsAttention: true,
      );
    }
    if (failed > 0) {
      return WingPluginOverview(
        'Some profiles need attention',
        'Open Profiles to see the reason. Refresh before trying again.',
        counts,
        installed,
        needsAttention: true,
      );
    }
    if (rows.isEmpty) {
      return WingPluginOverview(
        'No profiles found',
        'Refresh to check this server’s profiles.',
        'No profiles found',
        installed,
      );
    }
    if (missing == rows.length) {
      return WingPluginOverview(
        'Not installed',
        'Install Wing on this server for all profiles.',
        'Not installed',
        null,
      );
    }
    if (ready == rows.length) {
      return WingPluginOverview(
        'Up to date',
        'Wing is installed and enabled in every profile.',
        '${release!.version.value} · all $ready profiles',
        installed,
      );
    }
    if (pinned > 0) {
      return WingPluginOverview(
        'Older version is pinned',
        'Review the pinned replacement before updating all profiles.',
        counts,
        installed,
      );
    }
    return WingPluginOverview(
      'Setup incomplete',
      'Install, update or enable Wing where needed.',
      counts,
      installed,
    );
  }
}
