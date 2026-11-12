import '../cli.dart' as cli;
import '../model.dart';
import '../view_adapter_dependencies.dart';

const id = 'ARCH_TOOL_SETUP_VIEW_DEPENDENCIES';
const view = 'lib/core/screens/administration/admin_tool_setup_page.dart';
const _adapters = {
  'lib/core/services/profile_gateway.dart',
  'lib/core/services/administration_repository.dart',
};

/// Both setup and model views belong to this completed library and its parts.
List<Finding> check(Snapshot snapshot) => checkViewAdapterDependencies(
  snapshot,
  id: id,
  view: view,
  viewClass: 'AdminToolSetupPage',
  adapters: _adapters,
  message:
      'Use the typed tool setup owner and observations; raw profile adapters belong outside the completed view library.',
  missingViewMessage: 'Completed tool setup view missing/ambiguous',
  detachedPartMessage: 'Tool setup part is not declared by its owner',
);

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
