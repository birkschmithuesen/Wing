import '../cli.dart';
import '../model.dart';

const id = 'ARCH_DOMAIN_DEPENDENCY';
List<Finding> check(Snapshot snapshot) => forbiddenDependencies(
  snapshot,
  id: id,
  sourceRoles: {'domain'},
  forbiddenRoles: {
    'data',
    'application',
    'presentation',
    'view',
    'composition',
    'platform',
  },
  forbiddenExternal: (uri) =>
      uri == 'dart:io' ||
      uri == 'dart:isolate' ||
      uri == 'package:flutter/material.dart' ||
      uri == 'package:flutter/cupertino.dart' ||
      uri == 'package:flutter/widgets.dart' ||
      [
        'package:http/',
        'package:web_socket_channel/',
        'package:shared_preferences/',
        'package:flutter_secure_storage/',
        'package:path_provider/',
        'package:flutter/services.dart',
      ].any(uri.startsWith),
  allowedExternal: (dependency) =>
      dependency.uri == 'package:flutter/widgets.dart' &&
      dependency.pureWidgetHelpers,
  remedy: 'Keep domain values pure; move I/O and orchestration to their owner.',
);
void main(List<String> args) => run(args, {id: check});
