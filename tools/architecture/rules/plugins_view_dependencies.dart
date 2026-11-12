import '../cli.dart' as cli;
import '../model.dart';
import '../view_adapter_dependencies.dart';

const id = 'ARCH_PLUGINS_VIEW_DEPENDENCIES';
const view = 'lib/core/screens/administration/admin_plugins_page.dart';
const _adapters = {
  'lib/core/services/administration_repository.dart',
  'lib/core/services/profile_gateway.dart',
};

/// Plugins views render typed captured-server observations.
List<Finding> check(Snapshot snapshot) => checkViewAdapterDependencies(
  snapshot,
  id: id,
  view: view,
  viewClass: 'AdminPluginsPage',
  adapters: _adapters,
  message:
      'Use the typed Plugins owner and observations; raw profile adapters belong outside the completed Plugins view library.',
  missingViewMessage: 'Completed Plugins view missing/ambiguous',
  detachedPartMessage: 'Plugins view part is not declared by its owner',
);

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
