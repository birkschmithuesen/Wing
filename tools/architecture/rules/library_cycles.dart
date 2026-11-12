import '../cli.dart';
import '../model.dart';

const id = 'ARCH_LIBRARY_CYCLE';
List<Finding> check(Snapshot snapshot) {
  final result = <Finding>[];
  final closures = {
    for (final library in snapshot.graph.keys)
      library: snapshot.reachable(library),
  };
  final seen = <String>{};
  for (final source in snapshot.sources.values) {
    final owner = snapshot.libraries[source.path]!;
    for (final dependency in source.dependencies) {
      final target = snapshot.libraries[dependency.target];
      if (target == null || !(closures[target]?.contains(owner) ?? false)) {
        continue;
      }
      final subject = '${dependency.kind}:$target';
      if (seen.add('${source.path}:$subject')) {
        result.add(
          Finding(
            id,
            source.path,
            dependency.line,
            subject,
            'Break this authored-library cycle by moving shared facts to their owner.',
          ),
        );
      }
    }
  }
  return result;
}

void main(List<String> args) => run(args, {id: check});
