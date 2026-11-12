import 'selection_viewport.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/wing_theme.dart';
import 'studio_action_label.dart';
import 'studio_error.dart';

/// Optional contributions, shown only in App settings / About.
class SupportWingSection extends StatefulWidget {
  const SupportWingSection({
    super.key,
    required this.githubUri,
    required this.koFiUri,
  });

  final Uri githubUri;
  final Uri koFiUri;

  @override
  State<SupportWingSection> createState() => _SupportWingSectionState();
}

class _SupportWingSectionState extends State<SupportWingSection> {
  Uri? _opening;
  Uri? _failed;

  Future<void> _open(Uri uri) async {
    if (_opening != null) return;
    setState(() {
      _opening = uri;
      _failed = null;
    });
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // A missing browser or platform failure must leave settings usable.
    }
    if (!mounted) return;
    setState(() {
      _opening = null;
      _failed = opened ? null : uri;
    });
  }

  Widget _supportRow({
    required Uri uri,
    required String label,
    required String platform,
    required IconData icon,
    required bool primary,
  }) {
    final theme = Theme.of(context);
    final tokens = WingTokens.of(context);
    final enabled = _opening == null;
    final color = !enabled
        ? tokens.muted
        : primary
        ? tokens.accent
        : tokens.onSurface;
    return StudioButtonPress(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        minTileHeight: 48,
        enabled: enabled,
        textColor: color,
        titleTextStyle:
            (primary
                    ? theme.textTheme.titleMedium
                    : theme.listTileTheme.titleTextStyle)
                ?.copyWith(color: color),
        title: Semantics(
          hint: 'Opens $platform in your browser',
          child: IconTheme(
            data: IconThemeData(color: primary ? color : tokens.muted),
            child: StudioActionLabel.row(
              label,
              busy: _opening == uri,
              icon: icon,
            ),
          ),
        ),
        trailing: SizedBox.square(
          dimension: 18,
          child: _opening == uri
              ? CircularProgressIndicator(
                  strokeWidth: 2,
                  backgroundColor: Theme.of(context).colorScheme.outlineVariant,
                  value: MediaQuery.disableAnimationsOf(context) ? 0.75 : null,
                  semanticsLabel: 'Opening $platform',
                )
              : Icon(
                  Icons.open_in_new,
                  size: 18,
                  color: primary ? color : tokens.muted,
                ),
        ),
        onTap: enabled ? () => _open(uri) : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(WingSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text('Support Wing', style: theme.textTheme.titleMedium),
          ),
          const SizedBox(height: WingSpacing.sm),
          const Text(
            'If Wing is useful in your day, you can buy me a coffee and help me keep improving it.',
          ),
          const SizedBox(height: WingSpacing.sm),
          Text(
            'Completely optional. Every feature is available either way.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: WingTokens.of(context).muted,
            ),
          ),
          const SizedBox(height: WingSpacing.md),
          _supportRow(
            uri: widget.githubUri,
            label: 'Sponsor on GitHub',
            platform: 'GitHub Sponsors',
            icon: Icons.favorite_border,
            primary: true,
          ),
          const Divider(height: 1),
          _supportRow(
            uri: widget.koFiUri,
            label: 'Buy me a coffee',
            platform: 'Ko-fi',
            icon: Icons.coffee_outlined,
            primary: false,
          ),
          if (_failed != null) ...[
            const SizedBox(height: WingSpacing.md),
            const StudioError(
              'Could not open your browser. Please try again or open this link in a browser:',
            ),
            const SizedBox(height: WingSpacing.sm),
            viewportSelection(SelectableText(_failed.toString())),
          ],
        ],
      ),
    );
  }
}
