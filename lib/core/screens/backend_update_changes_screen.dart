import '../widgets/selection_viewport.dart';
import 'package:flutter/material.dart';

import '../models/backend_update.dart';
import '../theme/wing_theme.dart';
import '../widgets/compact_switch.dart';
import 'administration/admin_widgets.dart';

/// A captured update check: reading changes never starts an update or a request.
class BackendUpdateChangesScreen extends StatefulWidget {
  static const comparisonUnavailableMessage =
      'Hermes could not compare this installation with upstream.';

  final BackendUpdateCheck check;
  final String connectionLabel;

  const BackendUpdateChangesScreen({
    super.key,
    required this.check,
    required this.connectionLabel,
  });

  @override
  State<BackendUpdateChangesScreen> createState() =>
      _BackendUpdateChangesScreenState();
}

class _BackendUpdateChangesScreenState
    extends State<BackendUpdateChangesScreen> {
  bool _details = false;

  @override
  Widget build(BuildContext context) {
    final check = widget.check;
    final commits = check.commits;
    final count = commits.length;
    final behind = check.behind;
    final theme = Theme.of(context);
    final metadata = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return AdminPage(
      title: 'Changes in this update',
      scope: widget.connectionLabel,
      child: viewportSelection(
        SelectionArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (check.currentVersion case final version?) ...[
                Text('Installed backend $version', style: metadata),
                const SizedBox(height: 8),
              ],
              if (commits.isEmpty)
                Text(
                  !check.failed &&
                          check.updateAvailable == true &&
                          check.behind == null
                      ? BackendUpdateChangesScreen.comparisonUnavailableMessage
                      : 'Hermes did not provide change details for this update.',
                )
              else ...[
                Text(
                  behind != null && behind > count
                      ? 'Showing $count of $behind commits'
                      : '$count commit${count == 1 ? '' : 's'} shown',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text('From Hermes, newest first', style: metadata),
                if (commits.any((c) => c.sha != null || c.author != null))
                  CompactSwitchListTile(
                    title: const Text('Commit details'),
                    contentPadding: EdgeInsets.zero,
                    value: _details,
                    onChanged: (value) => setState(() => _details = value),
                  ),
                const SizedBox(height: 8),
                for (final commit in commits) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          commit.summary,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (commit.date case final date?) ...[
                          const SizedBox(height: 8),
                          Text(
                            '${MaterialLocalizations.of(context).formatMediumDate(date.toLocal())}, ${date.toLocal().year}',
                            style: metadata,
                          ),
                        ],
                        if (_details) ...[
                          if (commit.author case final author?) ...[
                            const SizedBox(height: 8),
                            Text('Author: $author', style: metadata),
                          ],
                          if (commit.sha case final sha?) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Commit: $sha',
                              style: WingTokens.of(context).typography.mono,
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
