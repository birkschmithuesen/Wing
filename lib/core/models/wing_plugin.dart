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
  const WingPluginRelease(this.version);
  static const repository = 'https://github.com/tarkilhk/wing-hermes-plugin';
  final WingPluginVersion version;
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
    return WingPluginRelease(version);
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
