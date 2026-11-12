import '../cli.dart' as cli;
import '../model.dart';
import '../view_adapter_dependencies.dart';

const id = 'ARCH_OUTPUTS_VIEW_DEPENDENCIES';
const view = 'lib/core/screens/chat_outputs_screen.dart';
const _adapters = {
  'lib/core/services/profile_gateway.dart',
  'lib/core/services/remote_file_saver.dart',
  'lib/core/services/android_file_delivery_service.dart',
  'lib/core/services/media_preview_service.dart',
  'lib/core/services/web_preview.dart',
};

/// Find renders issued matches; captured history and selection stay with owners.
List<Finding> check(Snapshot snapshot) => checkViewAdapterDependencies(
  snapshot,
  id: id,
  view: view,
  viewClass: 'ChatOutputsScreen',
  adapters: _adapters,
  message:
      'Use the typed output owner and observations; raw history, preview and delivery adapters belong outside the completed Outputs view library.',
  missingViewMessage: 'Completed Outputs view missing/ambiguous',
  detachedPartMessage: 'Outputs view part is not declared by its owner',
);

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
