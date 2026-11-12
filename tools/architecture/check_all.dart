import 'rules/form_confirmation_actions.dart' as forms;
import 'rules/compact_dialog_layout.dart' as dialogs;
import 'cli.dart';
import 'rules/activity_density.dart' as density;
import 'rules/loading_family.dart' as loading;
import 'model.dart';
import 'rules/business_rendering_types.dart' as rendering;
import 'rules/business_view_dependencies.dart' as business;
import 'rules/domain_dependencies.dart' as domain;
import 'rules/library_cycles.dart' as cycles;
import 'rules/role_inventory.dart' as inventory;
import 'rules/view_lowlevel_dependencies.dart' as views;
import 'rules/view_draft_write.dart' as draft;
import 'dead_code/retired_declarations.dart' as retired;
import 'rules/image_codec_confinement.dart' as codec;
import 'rules/image_codec_provenance.dart' as codec_provenance;
import 'rules/task_view_protocol.dart' as task_protocol;
import 'rules/recent_capture_release_safe.dart' as recent_capture;

final allRules = <String, Rule>{
  forms.id: forms.check,
  dialogs.id: dialogs.check,
  density.id: density.check,
  loading.id: loading.check,
  domain.id: domain.check,
  business.id: business.check,
  rendering.id: rendering.check,
  cycles.id: cycles.check,
  inventory.id: inventory.check,
  views.id: views.check,
  draft.id: (snapshot) => draft.check(snapshot, snapshot.root),
  retired.id: retired.check,
  codec.id: codec.check,
  codec_provenance.id: codec_provenance.check,
  task_protocol.id: (snapshot) => task_protocol.check(snapshot, snapshot.root),
  recent_capture.id: recent_capture.checkSnapshot,
};
Future<void> main(List<String> args) => run(args, allRules);
