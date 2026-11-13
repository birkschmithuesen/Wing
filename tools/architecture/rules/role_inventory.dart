import '../cli.dart';
import '../model.dart';

const id = 'ARCH_ROLE_INVENTORY';
List<Finding> check(Snapshot snapshot) {
  final result = <Finding>[];
  for (final source in snapshot.sources.values) {
    final role = snapshot.classifications[source.path];
    if (role == null) {
      result.add(
        Finding(
          id,
          source.path,
          1,
          'missing-role',
          'Classify this authored file by feature, role and actual library.',
        ),
      );
      continue;
    }
    if (role.library != snapshot.libraries[source.path]) {
      result.add(
        Finding(
          id,
          source.path,
          1,
          'library-owner',
          'Declare the actual library owner; only part directives combine files.',
        ),
      );
    }
    final owners = snapshot.partOwners[source.path] ?? const <String>[];
    if (owners.length > 1) {
      result.add(
        Finding(
          id,
          source.path,
          1,
          'multiple-part-owners',
          'A part must belong to exactly one authored library.',
        ),
      );
    }
    if ((source.partOf != null || source.namedPartOf) && owners.length != 1) {
      result.add(
        Finding(
          id,
          source.path,
          1,
          'unowned-part',
          'A part-of file needs its actual containing library in this scope.',
        ),
      );
    }
    if (source.partOf != null &&
        owners.length == 1 &&
        source.partOf != owners.single) {
      result.add(
        Finding(
          id,
          source.path,
          1,
          'mismatched-part-of',
          'Part and part-of declarations must identify the same library.',
        ),
      );
    }
    if (owners.length == 1) {
      final parent = snapshot.classifications[owners.single];
      if (parent != null &&
          (parent.role != role.role || parent.feature != role.feature)) {
        result.add(
          Finding(
            id,
            source.path,
            1,
            'part-role',
            'A part shares its containing library role and feature.',
          ),
        );
      }
    }
    for (final target in source.partTargets) {
      if (!snapshot.sources.containsKey(target)) {
        result.add(
          Finding(
            id,
            source.path,
            1,
            'missing-part:$target',
            'Declared part is absent from authored source.',
          ),
        );
      }
    }
  }
  for (final path in snapshot.classifications.keys) {
    if (!snapshot.sources.containsKey(path)) {
      result.add(
        Finding(
          id,
          path,
          1,
          'stale-role',
          'Remove the stale authored-file classification.',
        ),
      );
    }
  }
  return result;
}

void main(List<String> args) => run(args, {id: check});
