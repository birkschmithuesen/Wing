import '../cli.dart' as cli;
import '../model.dart';
import '../view_adapter_dependencies.dart';

const id = 'ARCH_VOICE_VIEW_DEPENDENCIES';
const view = 'lib/core/screens/administration/admin_voice_page.dart';
const _adapters = {
  'lib/core/services/administration_repository.dart',
  'lib/core/services/profile_gateway.dart',
};

/// Voice views render typed captured-profile observations.
List<Finding> check(Snapshot snapshot) => checkViewAdapterDependencies(
  snapshot,
  id: id,
  view: view,
  viewClass: 'AdminVoicePage',
  adapters: _adapters,
  message:
      'Use the typed Voice owner and observations; raw profile adapters belong outside the completed Voice view library.',
  missingViewMessage: 'Completed Voice view missing/ambiguous',
  detachedPartMessage: 'Voice view part is not declared by its owner',
);

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
