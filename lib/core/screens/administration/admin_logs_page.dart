import '../../widgets/selection_viewport.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:flutter/material.dart';
import '../../models/administration_logs.dart';
import '../../services/administration_logs_session.dart';
import '../../widgets/read_recovery.dart';
import '../../theme/wing_theme.dart';
import '../../widgets/studio_select.dart';
import 'admin_widgets.dart';

class AdminLogsPage extends StatefulWidget {
  final AdministrationLogsSession Function() createSession;
  const AdminLogsPage({super.key, required this.createSession});
  @override
  State<AdminLogsPage> createState() => _AdminLogsPageState();
}

class _AdminLogsPageState extends State<AdminLogsPage> {
  late final _session = widget.createSession();
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _session,
    builder: (context, _) => AdminPage(
      title: 'Logs',
      scope: _session.scopeLabel,
      actions: [
        StudioButtonPress(
          child: IconButton(
            tooltip: 'Refresh logs',
            onPressed: _session.refresh,
            icon: const Icon(Icons.refresh),
          ),
        ),
      ],
      child: ReadRecovery(
        shouldRetry: () => _session.state.canRecoverRead,
        retry: _session.refresh,
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final scaledWidth =
                          constraints.maxWidth /
                          (MediaQuery.textScalerOf(context).scale(16) / 16);
                      final width = scaledWidth < 340
                          ? constraints.maxWidth
                          : (constraints.maxWidth - 12) / 2;
                      return Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          SizedBox(
                            width: width,
                            child: StudioSelect<AdministrationLogFile>(
                              value: _session.state.query.file,
                              label: 'Log',
                              options: [
                                for (final file in AdministrationLogFile.values)
                                  (value: file, label: file.name),
                              ],
                              onChanged: (v) => _session.selectFile(v!),
                            ),
                          ),
                          SizedBox(
                            width: width,
                            child: StudioSelect<AdministrationLogLevel>(
                              value: _session.state.query.level,
                              label: 'Severity',
                              options: [
                                for (final level
                                    in AdministrationLogLevel.values)
                                  (value: level, label: level.label),
                              ],
                              onChanged: (v) => _session.selectLevel(v!),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  viewportSelection(
                    TextField(
                      decoration: const InputDecoration(
                        hintText: 'Search logs',
                        prefixIcon: Icon(Icons.search),
                      ),
                      textInputAction: TextInputAction.search,
                      onSubmitted: _session.search,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: StudioLoadingRegion(
                available: _session.state.snapshot != null,
                busy: _session.state.loading,
                label: 'Loading logs',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_session.state.error case final error?)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: AdminNotice.error(
                          error,
                          retry: _session.state.loading
                              ? null
                              : _session.refresh,
                        ),
                      ),
                    if (_session.state.snapshot case final snapshot?)
                      KeyedSubtree(
                        key: const ValueKey('content'),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Latest ${snapshot.lines.length} matching lines · Up to ${snapshot.query.limit}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 12),
                            AdminGroup(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: viewportSelection(
                                      SelectableText(
                                        snapshot.lines.isEmpty
                                            ? 'No matching log entries.'
                                            : snapshot.lines.join('\n'),
                                        style: WingTokens.of(
                                          context,
                                        ).typography.mono,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
