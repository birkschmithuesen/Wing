import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import '../cli.dart' as cli;
import '../model.dart';

const id = 'ARCH_RETIRED_ANSWER_VERSIONS_NAMESPACE';
const library = 'lib/core/services/profile_workspace_controller.dart';
const prefix = 'answer_versions_v1_';

/// Exact retired literal namespace in its former containing workspace library.
/// This does not evaluate aliases, arbitrary expressions or storage behavior.
List<Source> _namespace(Snapshot snapshot) {
  final source = snapshot.sources[library];
  if (source == null ||
      snapshot.libraries[library] != library ||
      source.partOf != null ||
      source.namedPartOf) {
    throw const FormatException(
      'Canonical retired-answer namespace containing library required',
    );
  }
  final targets = source.partTargets.toSet();
  if (targets.length !=
      source.ast.directives.whereType<PartDirective>().length) {
    throw const FormatException(
      'Unresolved or duplicate retired-answer namespace parts',
    );
  }
  final units = <Source>[source];
  for (final target in targets) {
    final part = snapshot.sources[target];
    final owners = snapshot.partOwners[target] ?? const <String>[];
    if (part == null ||
        part.partOf != library ||
        part.namedPartOf ||
        part.partTargets.isNotEmpty ||
        owners.length != 1 ||
        owners.single != library ||
        snapshot.libraries[target] != library) {
      throw FormatException(
        'Unsupported reciprocal retired-answer namespace part: $target',
      );
    }
    units.add(part);
  }
  if (snapshot.sources.values.any(
    (part) => part.partOf == library && !targets.contains(part.path),
  )) {
    throw const FormatException('Orphan retired-answer namespace part');
  }
  return units;
}

List<Finding> check(Snapshot snapshot) {
  final findings = <Finding>[];
  for (final source in _namespace(snapshot)) {
    final literals = _RetiredLiterals(source);
    source.ast.accept(literals);
    findings.addAll(literals.findings);
  }
  return findings..sort();
}

class _RetiredLiterals extends RecursiveAstVisitor<void> {
  _RetiredLiterals(this.source);
  final Source source;
  final findings = <Finding>[];

  bool _record(AstNode node, String? value) {
    if (value?.startsWith(prefix) != true) {
      return false;
    }
    findings.add(
      Finding(
        id,
        source.path,
        source.lineAt(node.offset),
        prefix,
        'Remove the retired answer-versions preferences namespace from its canonical workspace owner.',
      ),
    );
    return true;
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    _record(node, node.value);
  }

  @override
  void visitAdjacentStrings(AdjacentStrings node) {
    // Constant adjacent literal fragments form one actual Dart string.
    if (!_record(node, node.stringValue)) {
      super.visitAdjacentStrings(node);
    }
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    for (final fragment in node.elements.whereType<InterpolationString>()) {
      _record(fragment, fragment.value);
    }
    // Expressions inside interpolation may contain an independent literal.
    super.visitStringInterpolation(node);
  }
}

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
