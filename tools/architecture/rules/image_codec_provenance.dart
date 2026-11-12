import 'dart:io';

import 'package:yaml/yaml.dart';

import '../cli.dart';
import '../model.dart';

const id = 'ARCH_IMAGE_CODEC_PROVENANCE';
// These audited artifacts are code, not a migration baseline. Updating them
// requires re-auditing the allocation drivers and codec parity fixtures.
const auditedCodecs = {
  'image': (
    '4.12.0',
    '89ed75b2f8231fe676808c5564f9590d728024ded7ac782a7ed8474f1c95b72a',
  ),
  'archive': (
    '4.6.0',
    'de5ac590b8155e4e676088d714bd41ea620449a6adc0f7950c5073874b287ddb',
  ),
};
List<Finding> check(Snapshot snapshot) {
  final spec = loadYaml(
    File('${snapshot.root}/pubspec.yaml').readAsStringSync(),
  );
  final lock = loadYaml(
    File('${snapshot.root}/pubspec.lock').readAsStringSync(),
  );
  if (spec is! YamlMap ||
      lock is! YamlMap ||
      spec['dependencies'] is! YamlMap ||
      lock['packages'] is! YamlMap) {
    throw const FormatException('Codec provenance requires package manifests.');
  }
  final findings = <Finding>[];
  final dependencies = spec['dependencies'] as YamlMap;
  final image = dependencies.nodes['image'];
  if (image?.value != auditedCodecs['image']!.$1) {
    findings.add(
      Finding(
        id,
        'pubspec.yaml',
        (image?.span.start.line ?? 0) + 1,
        'image:exact-pin',
        'Pin the image codec to its audited exact version.',
      ),
    );
  }
  final overrides = spec['dependency_overrides'];
  if (overrides is Map) {
    for (final name in auditedCodecs.keys) {
      if (overrides.containsKey(name)) {
        findings.add(
          Finding(
            id,
            'pubspec.yaml',
            spec.span.start.line + 1,
            '$name:override',
            'An override invalidates the audited codec artifact.',
          ),
        );
      }
    }
  }
  final overrideFile = File('${snapshot.root}/pubspec_overrides.yaml');
  if (overrideFile.existsSync()) {
    final overrideDocument = loadYaml(overrideFile.readAsStringSync());
    if (overrideDocument is! YamlMap) {
      throw const FormatException('Invalid package override manifest.');
    }
    final overrideEntries = overrideDocument['dependency_overrides'];
    if (overrideEntries != null && overrideEntries is! YamlMap) {
      throw const FormatException('Invalid dependency overrides.');
    }
    if (overrideEntries is YamlMap) {
      for (final name in auditedCodecs.keys) {
        if (overrideEntries.containsKey(name)) {
          findings.add(
            Finding(
              id,
              'pubspec_overrides.yaml',
              overrideEntries.nodes[name]!.span.start.line + 1,
              '$name:override-file',
              'A package override invalidates the audited codec artifact.',
            ),
          );
        }
      }
    }
  }
  for (final entry in auditedCodecs.entries) {
    final node = (lock['packages'] as YamlMap).nodes[entry.key];
    if (node is! YamlMap) {
      throw FormatException('Missing codec lock entry: ${entry.key}.');
    }
    final description = node['description'];
    if (node['version'] != entry.value.$1 ||
        node['source'] != 'hosted' ||
        description is! Map ||
        description['name'] != entry.key ||
        description['url'] != 'https://pub.dev' ||
        description['sha256'] != entry.value.$2) {
      findings.add(
        Finding(
          id,
          'pubspec.lock',
          node.span.start.line + 1,
          '${entry.key}:artifact',
          'Codec allocation audit requires the exact hosted version and artifact hash.',
        ),
      );
    }
  }
  return findings;
}

void main(List<String> args) => run(args, {id: check});
