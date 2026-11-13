import '../cli.dart' as cli;
import '../model.dart';
import '../view_adapter_dependencies.dart';

const id = 'ARCH_BROWSER_VIEW_DEPENDENCIES';
const view = 'lib/core/screens/profile_workspace_browser.dart';
const _adapters = {
  'lib/core/services/profile_workspace_controller.dart',
  'lib/core/services/profile_gateway.dart',
};

/// browser views render typed captured-server observations.
List<Finding> check(Snapshot snapshot) => checkViewAdapterDependencies(
  snapshot,
  id: id,
  view: view,
  viewClass: 'ProfileWorkspaceBrowser',
  adapters: _adapters,
  message:
      'Use the typed browser owner and observations; raw profile adapters belong outside the completed browser view library.',
  missingViewMessage: 'Completed browser view missing/ambiguous',
  detachedPartMessage: 'browser view part is not declared by its owner',
);

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
