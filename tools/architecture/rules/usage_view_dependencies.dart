import '../cli.dart' as cli;
import '../model.dart';
import '../view_adapter_dependencies.dart';

const id = 'ARCH_USAGE_VIEW_DEPENDENCIES';
const view = 'lib/core/screens/administration/admin_usage_dashboard.dart';
const _adapters = {
  'lib/core/services/administration_repository.dart',
  'lib/core/services/usage_analytics.dart',
};

/// Usage views render typed captured-server observations.
List<Finding> check(Snapshot snapshot) => checkViewAdapterDependencies(
  snapshot,
  id: id,
  view: view,
  viewClass: 'UsageDashboard',
  adapters: _adapters,
  message:
      'Use the typed Usage owner and observations; raw profile adapters belong outside the completed Usage view library.',
  missingViewMessage: 'Completed Usage view missing/ambiguous',
  detachedPartMessage: 'Usage view part is not declared by its owner',
);

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
