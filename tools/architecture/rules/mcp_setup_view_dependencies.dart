import '../cli.dart' as cli;
import '../model.dart';
import '../view_adapter_dependencies.dart';

const id = 'ARCH_MCP_SETUP_VIEW_DEPENDENCIES';
const view = 'lib/core/screens/administration/admin_mcp_setup_page.dart';
const _adapters = {
  'lib/core/services/administration_repository.dart',
  'lib/core/services/profile_gateway.dart',
};

/// Setup renders input controls; its captured owner decides and dispatches.
List<Finding> check(Snapshot snapshot) => checkViewAdapterDependencies(
  snapshot,
  id: id,
  view: view,
  viewClass: 'AdminMcpSetupPage',
  adapters: _adapters,
  message:
      'Use the typed MCP setup owner and observations; raw profile adapters belong outside the completed setup view library.',
  missingViewMessage: 'Completed MCP setup view missing/ambiguous',
  detachedPartMessage: 'MCP setup view part is not declared by its owner',
);

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
