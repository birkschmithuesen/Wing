import '../cli.dart' as cli;
import '../model.dart';
import '../view_adapter_dependencies.dart';

const id = 'ARCH_CONNECTORS_VIEW_DEPENDENCIES';
const view = 'lib/core/screens/administration/admin_connectors_page.dart';
const _adapters = {
  'lib/core/services/administration_repository.dart',
  'lib/core/services/profile_gateway.dart',
};

/// Connector views borrow typed inventory, detail and OAuth owners.
List<Finding> check(Snapshot snapshot) => checkViewAdapterDependencies(
  snapshot,
  id: id,
  view: view,
  viewClass: 'AdminConnectorsPage',
  adapters: _adapters,
  message:
      'Use typed connector owners and observations; raw profile adapters belong outside the completed connector view library.',
  missingViewMessage: 'Completed connector view missing/ambiguous',
  detachedPartMessage: 'Connector view part is not declared by its owner',
);

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
