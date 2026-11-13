import '../cli.dart' as cli;
import '../model.dart';
import '../view_adapter_dependencies.dart';

const id = 'ARCH_SLASH_COMPLETION_VIEW_DEPENDENCIES';
const view = 'lib/core/widgets/slash_command_suggestions.dart';
const _adapters = {'lib/core/services/profile_workspace_controller.dart'};

/// Suggestions render typed completion facts and forward captured draft intent.
List<Finding> check(Snapshot snapshot) => checkViewAdapterDependencies(
  snapshot,
  id: id,
  view: view,
  viewClass: 'SlashCommandSuggestions',
  adapters: _adapters,
  message:
      'Use typed completion and save callbacks; the raw workspace controller belongs outside the completed slash suggestions library.',
  missingViewMessage: 'Completed slash suggestions missing/ambiguous',
  detachedPartMessage: 'Slash suggestions part is not declared by its owner',
);

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
