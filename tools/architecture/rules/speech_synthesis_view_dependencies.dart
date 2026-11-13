import '../cli.dart' as cli;
import '../model.dart';
import '../view_adapter_dependencies.dart';

const id = 'ARCH_SPEECH_SYNTHESIS_VIEW_DEPENDENCIES';
const view = 'lib/core/screens/administration/admin_speech_synthesis_page.dart';
const _adapters = {
  'lib/core/services/administration_repository.dart',
  'lib/core/services/profile_gateway.dart',
  'lib/core/services/profile_voice_repository.dart',
  'lib/core/controllers/voice_output_controller.dart',
  'lib/core/services/android_voice.dart',
};

/// Speech synthesis views render typed captured-profile observations.
List<Finding> check(Snapshot snapshot) => checkViewAdapterDependencies(
  snapshot,
  id: id,
  view: view,
  viewClass: 'AdminSpeechSynthesisPage',
  adapters: _adapters,
  message:
      'Use the typed Speech synthesis owner and observations; raw profile adapters belong outside the completed Speech synthesis view library.',
  missingViewMessage: 'Completed Speech synthesis view missing/ambiguous',
  detachedPartMessage:
      'Speech synthesis view part is not declared by its owner',
);

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
