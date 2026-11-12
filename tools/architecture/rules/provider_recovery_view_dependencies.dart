import '../cli.dart' as cli;
import '../model.dart';
import '../view_adapter_dependencies.dart';

const id = 'ARCH_PROVIDER_RECOVERY_VIEW_DEPENDENCIES';
const view = 'lib/core/screens/administration/admin_provider_detail.dart';
const _adapters = {
  'lib/core/services/administration_repository.dart',
  'lib/core/services/profile_gateway.dart',
};

/// Provider recovery views render typed captured-server observations.
List<Finding> check(Snapshot snapshot) => checkViewAdapterDependencies(
  snapshot,
  id: id,
  view: view,
  viewClass: 'AdminProviderDetail',
  adapters: _adapters,
  message:
      'Use the typed ProviderRecovery owner and observations; raw profile adapters belong outside the completed provider recovery view library.',
  missingViewMessage: 'Completed Provider recovery view missing/ambiguous',
  detachedPartMessage:
      'Provider recovery view part is not declared by its owner',
);

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
