import '../cli.dart' as cli;
import '../model.dart';
import '../view_adapter_dependencies.dart';

const id = 'ARCH_SUPERVISION_VIEW_DEPENDENCIES';
const views = {
  'lib/core/widgets/profile_subagent_panel.dart': 'ProfileSubagentPanel',
  'lib/core/widgets/profile_goal_panel.dart': 'ProfileGoalPanel',
  'lib/core/widgets/profile_background_work_panel.dart':
      'ProfileBackgroundWorkPanel',
};
const _adapters = {'lib/core/services/profile_workspace_controller.dart'};

List<Finding> check(Snapshot snapshot) => [
  for (final entry in views.entries)
    ...checkViewAdapterDependencies(
      snapshot,
      id: id,
      view: entry.key,
      viewClass: entry.value,
      adapters: _adapters,
      message:
          'Render captured ProfileSupervisionSession observations; raw workspace/runtime coordination belongs outside completed supervision panels.',
      missingViewMessage: 'Completed supervision panel missing/ambiguous',
      detachedPartMessage:
          'Supervision panel part is not declared by its owner',
    ),
]..sort();

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
