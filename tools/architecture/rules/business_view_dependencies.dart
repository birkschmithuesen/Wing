import '../cli.dart';
import '../model.dart';

const id = 'ARCH_BUSINESS_VIEW_DEPENDENCY';
List<Finding> check(Snapshot snapshot) => forbiddenDependencies(
  snapshot,
  id: id,
  sourceRoles: businessRoles,
  forbiddenRoles: {'view', 'presentation', 'composition'},
  forbiddenExternal: (uri) =>
      uri == 'package:flutter/material.dart' ||
      uri == 'package:flutter/cupertino.dart',
  remedy:
      'Move rendering and view dependencies to presentation; expose typed feature observations.',
);
void main(List<String> args) => run(args, {id: check});
