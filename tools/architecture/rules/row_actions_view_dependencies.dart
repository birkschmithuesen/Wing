import '../cli.dart' as cli;
import '../model.dart';
import '../view_adapter_dependencies.dart';

const id = 'ARCH_ROW_ACTIONS_VIEW_DEPENDENCIES';
const view = 'lib/core/screens/profile_row_actions.dart';
const _adapters = {
  'lib/core/services/profile_workspace_controller.dart',
  'lib/core/services/profile_gateway.dart',
};

/// row actions views render typed captured-server observations.
List<Finding> check(Snapshot snapshot) => checkViewAdapterDependencies(
  snapshot,
  id: id,
  view: view,
  viewClass: '_ChatProjectSheet',
  adapters: _adapters,
  message:
      'Use the typed row actions owner and observations; raw profile adapters belong outside the completed row actions view library.',
  missingViewMessage: 'Completed row actions view missing/ambiguous',
  detachedPartMessage: 'row actions view part is not declared by its owner',
);

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
