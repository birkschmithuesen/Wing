import 'dart:convert';
import 'dart:io';
import 'package:wing/core/models/retained_memory.dart';
import '../../../test/support/retained_memory_fixture.dart';

void main() {
  var checks = 0;
  void check(bool value) {
    if (!value) {
      throw StateError('Retained memory contract failed');
    }
    checks++;
  }

  void reject(void Function() parse) {
    try {
      parse();
      throw StateError('Invalid retained memory accepted');
    } on FormatException {
      checks++;
    }
  }

  Map<String, dynamic> graph() =>
      jsonDecode(jsonEncode(currentMemoryGraph())) as Map<String, dynamic>;
  final wire = graph();
  final observed = RetainedMemoryGraph.fromResponse(wire);
  check(observed.cards[1].identity.value == 'memory:profile:1:222222222222');
  check(observed.cards[1].source == RetainedMemorySource.profile);
  check(observed.cards[1].matches('SECOND'));
  (wire['memory'] as List).clear();
  check(observed.cards.length == 2);
  final permuted = graph();
  (permuted['nodes'] as List).insert(
    0,
    (permuted['nodes'] as List).removeLast(),
  );
  check(
    RetainedMemoryGraph.fromResponse(permuted).cards[1].identity.value ==
        observed.cards[1].identity.value,
  );
  check(
    RetainedMemoryGraph.fromResponse({
      'memory': [],
      'nodes': [
        {'kind': 'skill', 'id': 'a-skill'},
      ],
    }).cards.isEmpty,
  );
  for (final id in <Object?>[
    null,
    7,
    'memory:memory:0',
    'memory:MEMORY.md:0:111111111111',
    'memory:memory:00:111111111111',
    'memory:memory:-1:111111111111',
    'memory:memory:0:UPPERCASE123',
    'skill',
  ]) {
    reject(() => RetainedMemoryIdentity.fromWire(id));
  }
  for (final field in ['source', 'title', 'body', 'fingerprint']) {
    final missing = graph();
    (missing['memory'][0] as Map).remove(field);
    reject(() => RetainedMemoryGraph.fromResponse(missing));
  }
  for (final field in ['id', 'kind', 'label', 'memorySource']) {
    final missing = graph();
    (missing['nodes'][0] as Map).remove(field);
    reject(() => RetainedMemoryGraph.fromResponse(missing));
  }
  final missingNode = graph();
  (missingNode['nodes'] as List).removeLast();
  reject(() => RetainedMemoryGraph.fromResponse(missingNode));
  final ambiguous = graph();
  (ambiguous['nodes'] as List).add(<String, dynamic>{...ambiguous['nodes'][0]});
  reject(() => RetainedMemoryGraph.fromResponse(ambiguous));
  final stale = graph();
  stale['memory'][1]['fingerprint'] = '333333333333';
  reject(() => RetainedMemoryGraph.fromResponse(stale));
  final wrongSource = graph();
  wrongSource['nodes'][1]['memorySource'] = 'memory';
  reject(() => RetainedMemoryGraph.fromResponse(wrongSource));
  final reorderedCards = graph();
  (reorderedCards['memory'] as List).insert(
    0,
    (reorderedCards['memory'] as List).removeLast(),
  );
  reject(() => RetainedMemoryGraph.fromResponse(reorderedCards));
  final identity = observed.cards[1].identity;
  check(
    RetainedMemoryDetail.fromResponse(
          identity,
          currentMemoryDetail(identity.value),
        ).content ==
        'Full second memory',
  );
  for (final field in ['ok', 'kind', 'id', 'label', 'content']) {
    final missing = currentMemoryDetail(identity.value)..remove(field);
    reject(() => RetainedMemoryDetail.fromResponse(identity, missing));
  }
  for (final delta in [
    {'id': 'memory:profile:0:222222222222'},
    {'kind': 'skill'},
    {'ok': false},
    {'content': 7},
  ]) {
    reject(
      () => RetainedMemoryDetail.fromResponse(identity, {
        ...currentMemoryDetail(identity.value),
        ...delta,
      }),
    );
  }
  stdout.writeln('Retained memory values: $checks checks passed');
}
