import '../cli.dart' as cli;
import '../model.dart';
import '../view_adapter_dependencies.dart';

const id = 'ARCH_CAPABILITIES_VIEW_DEPENDENCIES';
const view = 'lib/core/screens/profile_capabilities_screen.dart';
const _adapters = {
  'lib/core/services/profile_gateway.dart',
  'lib/core/services/administration_repository.dart',
};

/// The completed capabilities library may depend on typed owners, not adapters.
List<Finding> check(Snapshot snapshot) => checkViewAdapterDependencies(
  snapshot,
  id: id,
  view: view,
  viewClass: 'ProfileCapabilitiesScreen',
  adapters: _adapters,
  message:
      'Use the typed capabilities session and observations; raw profile adapters belong outside the completed view library.',
  missingViewMessage: 'Completed capabilities view missing/ambiguous',
  detachedPartMessage: 'Capabilities part is not declared by its owner',
);

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
