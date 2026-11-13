import '../cli.dart' as cli;
import '../model.dart';
import '../view_adapter_dependencies.dart';

const id = 'ARCH_SHARED_DRAFT_VIEW_DEPENDENCIES';
const view = 'lib/core/screens/shared_draft_review.dart';
const _adapters = {
  'lib/core/services/profile_workspace_controller.dart',
  'lib/core/services/attachment_draft_service.dart',
  'lib/core/services/android_share_intent_service.dart',
  'lib/core/models/composer_work.dart',
};

/// Review renders copied facts; destination, staging and ACK stay with owners.
List<Finding> check(Snapshot snapshot) => checkViewAdapterDependencies(
  snapshot,
  id: id,
  view: view,
  viewClass: '_SharedDraftReview',
  adapters: _adapters,
  message:
      'Use SharedDraftSession and copied observations; raw workspace, attachment, native intake and saved-work dependencies belong outside the completed share review library.',
  missingViewMessage: 'Completed shared draft review missing/ambiguous',
  detachedPartMessage: 'Shared draft review part is not declared by its owner',
);

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
