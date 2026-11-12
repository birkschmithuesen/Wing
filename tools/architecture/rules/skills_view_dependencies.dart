import '../cli.dart' as cli;
import '../model.dart';
import '../view_adapter_dependencies.dart';

const id = 'ARCH_SKILLS_VIEW_DEPENDENCIES';
const view = 'lib/core/screens/administration/admin_skills_page.dart';
const _adapters = {
  'lib/core/services/administration_repository.dart',
  'lib/core/services/profile_gateway.dart',
};

/// Library, detail, editor, Hub and preview share this completed view library.
List<Finding> check(Snapshot snapshot) => checkViewAdapterDependencies(
  snapshot,
  id: id,
  view: view,
  viewClass: 'AdminSkillLibraryPage',
  adapters: _adapters,
  message:
      'Use the typed skills owner and observations; raw profile adapters belong outside the completed view library.',
  missingViewMessage: 'Completed skills view missing/ambiguous',
  detachedPartMessage: 'Skills view part is not declared by its owner',
);

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
