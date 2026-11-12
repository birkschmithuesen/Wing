import '../../widgets/selection_viewport.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:flutter/material.dart';
import '../../models/provider_inventory.dart';
import '../../services/administration_repository.dart';
import '../../services/provider_inventory_session.dart';
import 'admin_widgets.dart';
import 'provider_recovery_routes.dart';
import 'admin_provider_credentials.dart';

class AdminProvidersPage extends StatefulWidget {
  const AdminProvidersPage({super.key, required this.profile});
  final ProfileAdministration profile;
  @override
  State<AdminProvidersPage> createState() => _AdminProvidersPageState();
}

class _AdminProvidersPageState extends State<AdminProvidersPage> {
  late final session = ProviderInventorySession(
    widget.profile,
    scope: ProviderInventoryScope.inventory,
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

  Future<void> _open(
    Widget Function(BuildContext, ProfileAdministration) builder,
  ) async {
    await adminPushProfile(context, session.profile, builder);
    await session.refresh();
  }

  String _expiry(ProviderInventoryEntry access) {
    final expiry = access.expiresAt?.toLocal();
    if (expiry == null) {
      return 'Expiry not reported';
    }
    final date = MaterialLocalizations.of(context).formatMediumDate(expiry);
    final time = TimeOfDay.fromDateTime(expiry).format(context);
    return '${access.expiryPrefix} $date · $time';
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    title: 'Profile access',
    scope: session.profile.label,
    child: ProviderInventoryBody(
      session: session,
      builder: (data) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Credentials for this profile · Availability is not a model test.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          viewportSelection(
            TextField(
              decoration: const InputDecoration(
                labelText: 'Search providers and keys',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: session.search,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final filter in ProviderInventoryFilter.values)
                StudioButtonPress(
                  child: ChoiceChip(
                    showCheckmark: false,
                    label: Text('${filter.label} (${data.count(filter)})'),
                    selected: session.filter == filter,
                    onSelected: (_) => session.selectFilter(filter),
                  ),
                ),
            ],
          ),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              StudioButtonPress(
                child: TextButton.icon(
                  onPressed: session.refresh,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Check status'),
                ),
              ),
              Text(
                'Checked ${TimeOfDay.fromDateTime(data.checkedAt).format(context)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          if (!data.selectionsAvailable)
            const AdminNotice.error(
              'Profile selections could not be loaded. Refresh to retry.',
            ),
          if (session.providers.isEmpty)
            const AdminNotice('No providers match this view.'),
          AdminGroup(
            children: [
              for (final access in session.providers)
                StudioButtonPress(
                  child: ListTile(
                    key: ValueKey('provider-${access.id}'),
                    title: Text(
                      access.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      '${access.statusLabel} · ${access.sourceLabel}${access.hasCredential ? '\n${_expiry(access)}' : ''}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (access.canSignInAgain)
                          StudioButtonPress(
                            child: IconButton(
                              tooltip: 'Sign in to ${access.name} again',
                              icon: const Icon(Icons.login),
                              onPressed: () => _open(
                                (context, profile) => AdminProviderSignIn(
                                  profile: profile,
                                  target: access.signIn!,
                                ),
                              ),
                            ),
                          ),
                        const Icon(Icons.chevron_right),
                      ],
                    ),
                    onTap: () => _open(
                      (context, profile) => providerRecoveryPage(
                        profile: profile,
                        providerId: access.id,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text('Service keys', style: Theme.of(context).textTheme.titleMedium),
          Align(
            alignment: Alignment.centerLeft,
            child: StudioButtonPress(
              child: IconButton.filled(
                tooltip: 'Add service key',
                onPressed: () => _open(
                  (context, profile) =>
                      AdminServiceKeyCatalog(profile: profile),
                ),
                icon: const Icon(Icons.add, size: 18),
              ),
            ),
          ),
          for (final field in session.keys)
            StudioButtonPress(
              child: ListTile(
                title: Text(field.key),
                subtitle: Text(
                  field.isSet ? 'Stored for this owner' : 'Not stored here',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _open(
                  (context, profile) =>
                      AdminSecretPage(profile: profile, name: field.key),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
