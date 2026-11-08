import 'dart:async';
import 'package:flutter/material.dart';
import '../services/wing_plugin_session.dart';
import '../theme/wing_theme.dart';
import 'studio_loading.dart';
import 'wing_plugin_page.dart';

/// Owns one captured backend across the card and its drill-down routes.
class WingPluginSettingsCard extends StatefulWidget {
  const WingPluginSettingsCard({super.key, required this.createSession});
  final WingPluginSession Function()? createSession;
  @override
  State<WingPluginSettingsCard> createState() => _WingPluginSettingsCardState();
}

class _WingPluginSettingsCardState extends State<WingPluginSettingsCard> {
  late final WingPluginSession? _session = widget.createSession?.call();
  final _routes = <MaterialPageRoute<void>>[];

  @override
  void initState() {
    super.initState();
    unawaited(_session?.refresh(explicit: false));
  }

  Future<void> _open({bool profiles = false}) async {
    if (!mounted || _session == null) return;
    if (!profiles && _routes.isNotEmpty || profiles && _routes.length > 1) {
      return;
    }
    final route = MaterialPageRoute<void>(
      builder: (_) => WingPluginPage(
        session: _session,
        profiles: profiles,
        openProfiles: () => unawaited(_open(profiles: true)),
      ),
    );
    _routes.add(route);
    try {
      await Navigator.of(context).push(route);
    } finally {
      _routes.remove(route);
    }
  }

  @override
  void dispose() {
    _session?.dispose();
    // An underlying connection/settings replacement retires all borrowed pages.
    final routes = _routes.reversed.toList();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final route in routes) {
        final navigator = route.navigator;
        if (route.isActive && navigator != null && navigator.mounted) {
          navigator.removeRoute(route);
        }
      }
    });
    super.dispose();
  }

  Widget _card(BuildContext context) {
    final overview = _session?.overview;
    final colors = Theme.of(context).colorScheme;
    return StudioPageLoading(
      active: _session?.explicitBusy ?? false,
      label: _session?.progressLabel ?? 'Checking Wing plugin versions',
      child: Card(
        child: StudioButtonPress(
          child: InkWell(
            onTap: _session == null ? null : () => unawaited(_open()),
            borderRadius: WingRadius.control,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const StudioWingMark(),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Wing plugin',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      if (_session != null) const Icon(Icons.chevron_right),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Text('Extra features for Wing.'),
                  const Divider(height: 28),
                  Row(
                    children: [
                      Icon(
                        overview?.needsAttention == true
                            ? Icons.error_outline
                            : Icons.extension_outlined,
                        size: 18,
                        color: overview?.needsAttention == true
                            ? colors.error
                            : colors.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          overview?.summary ??
                              'Connect to Hermes to manage the plugin.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _session == null
      ? _card(context)
      : ListenableBuilder(
          listenable: _session,
          builder: (context, _) => _card(context),
        );
}
