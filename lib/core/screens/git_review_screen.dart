import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/git_review.dart';
import '../services/git_review_session.dart';
import '../theme/wing_theme.dart';
import '../widgets/studio_error.dart';
import '../widgets/selection_viewport.dart';
import '../widgets/studio_loading.dart';
import '../widgets/wing_app_bar.dart';

/// Phone-width read-only review; the captured session owns all backend reads.
class GitReviewScreen extends StatefulWidget {
  const GitReviewScreen({
    super.key,
    required this.session,
    required this.scope,
  });
  final GitReviewSession session;
  final String scope;
  @override
  State<GitReviewScreen> createState() => _GitReviewScreenState();
}

class _GitReviewScreenState extends State<GitReviewScreen> {
  GitReviewSession get _session => widget.session;
  GitReviewLine? _copying;
  int _copyGeneration = 0;
  @override
  void initState() {
    super.initState();
    _session.refresh();
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  Future<void> _copy(BuildContext anchor, GitReviewLine line) async {
    if (_copying != null) return;
    const key = 'copy-git-reference';
    dismissTransientError(anchor, errorKey: key);
    final file = _session.selected;
    if (file == null) return;
    final comparison = _session.comparison;
    final generation = ++_copyGeneration;
    setState(() {
      _copying = line;
    });
    try {
      await Clipboard.setData(
        ClipboardData(text: line.reference(file.path, comparison)),
      );
      if (mounted &&
          generation == _copyGeneration &&
          identical(_session.selected, file) &&
          _session.comparison == comparison) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Reference copied')));
      }
    } catch (_) {
      if (anchor.mounted &&
          generation == _copyGeneration &&
          identical(_session.selected, file)) {
        showTransientError(
          anchor,
          'The reference could not be copied. Try again.',
          errorKey: key,
          icon: Icons.copy_outlined,
        );
      }
    } finally {
      if (mounted && generation == _copyGeneration) {
        setState(() => _copying = null);
      }
    }
  }

  void _retireCopy() {
    _copyGeneration++;
    _copying = null;
  }

  void _showFiles() {
    _retireCopy();
    _session.showFiles();
  }

  Future<void> _refresh() {
    _retireCopy();
    return _session.refresh();
  }

  Future<void> _open(
    GitReviewFile file, {
    GitReviewComparison comparison = GitReviewComparison.all,
  }) {
    _retireCopy();
    return _session.open(file, comparison: comparison);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _session,
    builder: (context, _) {
      final selected = _session.selected;
      return StudioLoadingFrame(
        child: PopScope(
          canPop: selected == null,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _showFiles();
          },
          child: Scaffold(
            appBar: WingAppBar(
              context: context,
              leading: StudioButtonPress(
                child: BackButton(
                  onPressed: () {
                    if (selected != null) {
                      _showFiles();
                    } else {
                      Navigator.of(context).pop();
                    }
                  },
                ),
              ),
              title: const Text('Git review'),
              actions: [
                StudioButtonPress(
                  child: IconButton(
                    tooltip: selected == null
                        ? 'Refresh changed files'
                        : 'Reload diff',
                    onPressed: _session.loading
                        ? null
                        : selected == null
                        ? _refresh
                        : () =>
                              _open(selected, comparison: _session.comparison),
                    icon: const Icon(Icons.refresh),
                  ),
                ),
              ],
            ),
            body: SafeArea(
              top: false,
              child: StudioPageLoading(
                active: _session.loading || _copying != null,
                label: _copying != null
                    ? 'Copying reference'
                    : selected == null
                    ? 'Loading changed files'
                    : 'Loading diff',
                child: CustomScrollView(
                  key: ValueKey((selected?.path, _session.comparison)),
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.scope,
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                            if (_session.workspace case final path?)
                              Text(
                                path,
                                style: WingTypography.ramp(
                                  Theme.of(context).brightness,
                                ).mono,
                              ),
                            if (selected != null) ...[
                              const SizedBox(height: 12),
                              viewportSelection(
                                SelectableText(
                                  selected.path,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children: [
                                  StudioButtonPress(
                                    child: ChoiceChip(
                                      showCheckmark: false,
                                      label: const Text('All changes'),
                                      selected:
                                          _session.comparison ==
                                          GitReviewComparison.all,
                                      onSelected: (_) => _open(selected),
                                    ),
                                  ),
                                  if (selected.staged)
                                    StudioButtonPress(
                                      child: ChoiceChip(
                                        showCheckmark: false,
                                        label: const Text('Staged'),
                                        selected:
                                            _session.comparison ==
                                            GitReviewComparison.staged,
                                        onSelected: (_) => _open(
                                          selected,
                                          comparison:
                                              GitReviewComparison.staged,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              Text(
                                _session.comparison == GitReviewComparison.all
                                    ? 'Working tree compared with HEAD'
                                    : 'Index compared with HEAD',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                            if (_session.error case final error?)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: StudioError(error),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SliverToBoxAdapter(child: Divider(height: 1)),
                    selected == null ? _files() : _diff(selected),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _files() {
    if (_session.observed && _session.files.isEmpty) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('No changed files reported for this workspace.'),
          ),
        ),
      );
    }
    return SliverList.separated(
      itemCount: _session.files.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final file = _session.files[index];
        return StudioButtonPress(
          child: ListTile(
            enabled: !_session.loading,
            title: Text(
              file.path,
              style: WingTokens.of(context).typography.mono,
            ),
            subtitle: Text(
              '${file.status} · +${file.added} −${file.removed}${file.staged ? ' · staged' : ''}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _open(file),
          ),
        );
      },
    );
  }

  Widget _diff(GitReviewFile file) {
    final diff = _session.diff;
    if (diff == null) return const SliverToBoxAdapter(child: SizedBox.shrink());
    if (diff.lines.isEmpty) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No diff returned for this comparison. Refresh changed files to check the latest state.',
            ),
          ),
        ),
      );
    }
    final firstHunk = diff.lines.indexWhere((line) => line.hunk);
    final lines = firstHunk < 0 ? diff.lines : diff.lines.sublist(firstHunk);
    final scheme = Theme.of(context).colorScheme;
    final mono = WingTokens.of(context).typography.mono;
    return SliverList.builder(
      itemCount: lines.length,
      itemBuilder: (context, index) {
        final line = lines[index];
        return ColoredBox(
          color: line.removed
              ? scheme.errorContainer.withValues(alpha: .3)
              : line.added
              ? scheme.primaryContainer.withValues(alpha: .3)
              : Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (line.oldLine != null || line.newLine != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 8, top: 4),
                    child: Text(
                      '−${line.oldLine ?? '·'}\n+${line.newLine ?? '·'}',
                      style: mono.copyWith(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: viewportSelection(
                      SelectableText(line.text, style: mono),
                    ),
                  ),
                ),
                if (line.canReference)
                  Builder(
                    builder: (anchor) => StudioButtonPress(
                      child: IconButton(
                        tooltip: line.hunk
                            ? 'Copy hunk reference'
                            : 'Copy changed line reference',
                        onPressed: _copying == null
                            ? () => _copy(anchor, line)
                            : null,
                        icon: const Icon(Icons.copy_outlined, size: 18),
                      ),
                    ),
                  ),
                if (!line.canReference) const SizedBox(width: 12),
              ],
            ),
          ),
        );
      },
    );
  }
}
