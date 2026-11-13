import '../cli.dart' as cli;
import '../model.dart';
import '../view_adapter_dependencies.dart';

const id = 'ARCH_FIND_VIEW_DEPENDENCIES';
const view = 'lib/core/widgets/chat_find_sheet.dart';
const _adapters = {
  'lib/core/services/profile_gateway.dart',
  'lib/core/services/profile_workspace_controller.dart',
};

/// Find renders issued matches; captured history and selection stay with owners.
List<Finding> check(Snapshot snapshot) => checkViewAdapterDependencies(
  snapshot,
  id: id,
  view: view,
  viewClass: 'ChatFindSheet',
  adapters: _adapters,
  message:
      'Use the typed reading owner and observations; raw history and workspace adapters belong outside the completed Find view library.',
  missingViewMessage: 'Completed Find view missing/ambiguous',
  detachedPartMessage: 'Find view part is not declared by its owner',
);

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
