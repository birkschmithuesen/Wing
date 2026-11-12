import '../cli.dart' as cli;
import '../model.dart';
import '../view_adapter_dependencies.dart';

const id = 'ARCH_LOGS_VIEW_DEPENDENCIES';
const view = 'lib/core/screens/administration/admin_logs_page.dart';
const _adapters = {
  'lib/core/services/administration_repository.dart',
  'lib/core/services/profile_gateway.dart',
};

/// Logs views render typed captured-server observations.
List<Finding> check(Snapshot snapshot) => checkViewAdapterDependencies(
  snapshot,
  id: id,
  view: view,
  viewClass: 'AdminLogsPage',
  adapters: _adapters,
  message:
      'Use the typed Logs owner and observations; raw profile adapters belong outside the completed Logs view library.',
  missingViewMessage: 'Completed Logs view missing/ambiguous',
  detachedPartMessage: 'Logs view part is not declared by its owner',
);

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
