import '../cli.dart';
import '../model.dart';

const id = 'ARCH_IMAGE_CODEC_CONFINEMENT';
const workerLibrary = 'lib/core/services/attachment_image_worker.dart';

/// Direct package provenance, including conditional directives and real parts.
/// Authored barrels cannot hide a codec import/export: their own edge fails.
/// This rule does not establish heap bounds or prove runtime isolate execution.
List<Finding> check(Snapshot snapshot) => [
  for (final source in snapshot.sources.values)
    for (final dependency in source.dependencies)
      if (dependency.uri.startsWith('package:image/') &&
          ((snapshot.libraries[source.path] ?? source.path) != workerLibrary ||
              dependency.kind == 'export'))
        Finding(
          id,
          source.path,
          dependency.line,
          dependency.subject,
          'Keep image codec imports inside the attachment worker library; '
          'do not export codec APIs into callers.',
        ),
];

void main(List<String> args) => run(args, {id: check});
