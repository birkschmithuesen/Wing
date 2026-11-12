import '../cli.dart' as cli;
import '../model.dart';
import '../view_adapter_dependencies.dart';

const id = 'ARCH_PROJECT_ACTIONS_VIEW_DEPENDENCIES';
const view = 'lib/core/screens/profile_project_actions.dart';
const _adapters = {
  'lib/core/services/profile_workspace_controller.dart',
  'lib/core/services/profile_gateway.dart',
};

/// project actions views render typed captured-server observations.
List<Finding> check(Snapshot snapshot) => checkViewAdapterDependencies(
  snapshot,
  id: id,
  view: view,
  viewClass: 'ProjectEditorDialog',
  adapters: _adapters,
  message:
      'Use the typed project actions owner and observations; raw profile adapters belong outside the completed project actions view library.',
  missingViewMessage: 'Completed project actions view missing/ambiguous',
  detachedPartMessage: 'project actions view part is not declared by its owner',
);

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
