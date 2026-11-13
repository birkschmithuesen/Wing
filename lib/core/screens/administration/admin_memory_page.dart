import '../../widgets/selection_viewport.dart';
import 'package:wing/core/widgets/studio_form_actions.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import '../../models/settings_edit.dart';
import '../../models/retained_memory.dart';
import '../../services/retained_memory_session.dart';
import '../../widgets/read_recovery.dart';
import 'package:flutter/material.dart';
import '../../services/administration_repository.dart';
import 'admin_settings_page.dart';
import 'admin_widgets.dart';

class AdminMemoryPage extends StatefulWidget {
  final ProfileAdministration profile;
  const AdminMemoryPage({super.key, required this.profile});
  @override
  State<AdminMemoryPage> createState() => _AdminMemoryPageState();
}

class _AdminMemoryPageState extends State<AdminMemoryPage> {
  late final session = RetainedMemoryCatalogSession(widget.profile);
  @override
  void initState() {
    super.initState();
    session.refresh();
  }

  @override
  void dispose() {
    session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    title: 'Memory',
    scope: session.profile.label,
    actions: [
      StudioButtonPress(
        child: IconButton(
          tooltip: 'Memory settings',
          icon: const Icon(Icons.tune),
          onPressed: () => adminPushProfile(
            context,
            session.profile,
            (context, profile) => AdminSettingsPage(
              profile: profile,
              title: 'Memory settings',
              fields: memoryFields,
            ),
          ),
        ),
      ),
    ],
    child: _MemoryReadBody<RetainedMemoryGraph>(
      listenable: session,
      facts: () => session.reading,
      refresh: session.refresh,
      builder: (data) {
        final rows = data.cards;
        final visible = session.cards;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            viewportSelection(
              TextField(
                decoration: const InputDecoration(
                  labelText: 'Search memories',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: session.searchFor,
              ),
            ),
            const SizedBox(height: 12),
            Text('Read only', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            if (rows.isEmpty)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Nothing remembered yet',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const AdminNotice('No retained memories in this profile.'),
                  StudioButtonPress(
                    child: TextButton(
                      onPressed: () => adminPushProfile(
                        context,
                        session.profile,
                        (context, profile) => AdminSettingsPage(
                          profile: profile,
                          title: 'Memory settings',
                          fields: memoryFields,
                        ),
                      ),
                      child: const Text('Memory settings'),
                    ),
                  ),
                ],
              ),
            if (rows.isNotEmpty && visible.isEmpty)
              const AdminNotice('No matching memories.'),
            for (final entry in visible)
              StudioButtonPress(
                child: ListTile(
                  title: Text(entry.title),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.preview,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'Source: ${entry.source.name}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => adminPushProfile(
                    context,
                    session.profile,
                    (context, profile) => AdminMemoryDetail(
                      profile: profile,
                      identity: entry.identity,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                StudioButtonPress(
                  child: TextButton.icon(
                    onPressed: session.refresh,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Refresh memories'),
                  ),
                ),
                StudioButtonPress(
                  child: TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (context) => StudioDialog(
                        title: const Text('Why read only?'),
                        content: const Text(
                          'You can read and copy these memories. Editing and deleting are unavailable in this Wing view. Retention and character budgets are available in Memory settings.',
                        ),
                        actions: [
                          StudioButtonPress(
                            child: IconButton(
                              tooltip: 'Close',
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(Icons.close),
                            ),
                          ),
                        ],
                      ),
                    ),
                    child: const Text('Why read only?'),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    ),
  );
}

class AdminMemoryDetail extends StatefulWidget {
  final ProfileAdministration profile;
  final RetainedMemoryIdentity identity;
  const AdminMemoryDetail({
    super.key,
    required this.profile,
    required this.identity,
  });
  @override
  State<AdminMemoryDetail> createState() => _AdminMemoryDetailState();
}

class _AdminMemoryDetailState extends State<AdminMemoryDetail> {
  late final session = RetainedMemoryDetailSession(
    widget.profile,
    widget.identity,
  );
  @override
  void initState() {
    super.initState();
    session.refresh();
  }

  @override
  void dispose() {
    session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    title: 'Retained memory',
    scope: session.profile.label,
    child: _MemoryReadBody<RetainedMemoryDetail>(
      listenable: session,
      facts: () => session.reading,
      refresh: session.refresh,
      builder: (data) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          viewportSelection(SelectableText(data.content)),
          const SizedBox(height: 24),
          const AdminNotice(
            'Read only. Editing and deleting are unavailable in this Wing view.',
          ),
          StudioButtonPress(
            child: TextButton(
              onPressed: session.refresh,
              child: const Text('Refresh'),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Renders passive reading facts; ordering, parsing and retention stay owned.
class _MemoryReadBody<T> extends StatelessWidget {
  const _MemoryReadBody({
    required this.listenable,
    required this.facts,
    required this.refresh,
    required this.builder,
  });
  final Listenable listenable;
  final RetainedMemoryReading<T> Function() facts;
  final Future<void> Function() refresh;
  final Widget Function(T) builder;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: listenable,
    builder: (context, _) {
      final reading = facts();
      return ReadRecovery(
        shouldRetry: () => facts().canRecover,
        retry: refresh,
        child: StudioLoadingRegion(
          available: reading.value != null,
          busy: reading.loading,
          label: 'Loading memory',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (reading.error case final error?)
                Flexible(
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: AdminNotice.error(
                        '${reading.checkedAt == null ? '' : 'Last checked ${TimeOfDay.fromDateTime(reading.checkedAt!).format(context)}. '}$error',
                        retry: reading.loading ? null : refresh,
                      ),
                    ),
                  ),
                ),
              if (reading.value case final value?)
                Expanded(key: const ValueKey('content'), child: builder(value)),
            ],
          ),
        ),
      );
    },
  );
}
