import '../../services/administration_repository.dart';
import '../../services/provider_recovery.dart';
import 'admin_provider_detail.dart';
import 'admin_provider_credentials.dart';
import 'admin_widgets.dart';

/// Captures the selected profile at route construction. The completed detail
/// library receives only its typed recovery factory and navigation callbacks.
AdminProviderDetail providerRecoveryPage({
  required ProfileAdministration profile,
  required String providerId,
}) => AdminProviderDetail(
  createSession: () => ProviderRecovery(profile, providerId: providerId),
  onDeviceSignIn: (context, target) => adminPushProfile(
    context,
    profile,
    (context, selected) =>
        AdminProviderSignIn(profile: selected, target: target),
  ),
  onKeys: (context) => adminPushProfile(
    context,
    profile,
    (context, selected) => AdminServiceKeyCatalog(profile: selected),
  ),
);
