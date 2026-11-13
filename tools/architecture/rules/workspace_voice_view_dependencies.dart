import '../cli.dart' as cli;
import '../model.dart';
import '../view_adapter_dependencies.dart';

const id = 'ARCH_WORKSPACE_VOICE_VIEW_DEPENDENCIES';
const view = 'lib/core/screens/profile_workspace_screen.dart';
const _adapters = {'lib/core/services/hermes_voice.dart'};

/// Native device constructor injection remains route composition. Captured
/// remote processing, target admission and completion belong to existing owners.
List<Finding> check(Snapshot snapshot) => checkViewAdapterDependencies(
  snapshot,
  id: id,
  view: view,
  viewClass: 'ProfileWorkspaceScreen',
  adapters: _adapters,
  message:
      'Use recorder/playback commands and captured workspace voice access; raw Hermes speech adapters belong outside the completed workspace voice namespace.',
  missingViewMessage: 'Completed workspace voice view missing/ambiguous',
  detachedPartMessage: 'Workspace voice part is not declared by its owner',
);

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
