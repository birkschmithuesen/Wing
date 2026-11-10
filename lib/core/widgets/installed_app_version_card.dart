import 'package:wing/core/theme/wing_theme.dart';
import 'studio_error.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'web_link_scope.dart';
import 'playful_portrait.dart';

const _changelogUrl = 'https://github.com/tarkilhk/Wing/blob/main/CHANGELOG.md';
const _releasesUrl = 'https://github.com/tarkilhk/Wing/releases';

typedef AppVersionLinkOpener = Future<bool> Function(Uri uri);

/// Displays the installed application's identity from Android package metadata.
class InstalledAppVersionCard extends StatefulWidget {
  const InstalledAppVersionCard({super.key, this.openLink});

  final AppVersionLinkOpener? openLink;

  @override
  State<InstalledAppVersionCard> createState() =>
      _InstalledAppVersionCardState();
}

class _InstalledAppVersionCardState extends State<InstalledAppVersionCard> {
  late final Future<PackageInfo> _info = PackageInfo.fromPlatform();

  Future<void> _open(String href) async {
    final uri = Uri.parse(href);
    final opened =
        await (widget.openLink?.call(uri) ?? WebLinkScope.open(context, uri));
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: StudioError('Could not open this link.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: _info,
      builder: (context, snapshot) {
        final info = snapshot.data;
        final unavailable =
            snapshot.hasError ||
            snapshot.connectionState == ConnectionState.done && info == null;
        return Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const PlayfulPortrait(),
                title: Text(
                  info == null || info.appName.trim().isEmpty
                      ? 'Wing'
                      : info.appName,
                ),
                subtitle: Text(
                  info != null
                      ? 'Version ${info.version}'
                      : unavailable
                      ? 'Version information is unavailable.'
                      : 'Version —',
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 4,
                  children: [
                    StudioButtonPress(
                      child: TextButton(
                        onPressed: () => _open(_changelogUrl),
                        child: const Text("What's new"),
                      ),
                    ),
                    StudioButtonPress(
                      child: TextButton(
                        onPressed: () => _open(_releasesUrl),
                        child: const Text('Releases'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
