import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/profile_identity_edit.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_identity_repository.dart';

const descriptionField = ProfileIdentityField.description;
const soulField = ProfileIdentityField.soul;

class _Host {
  String description = 'Opening description';
  String soul = 'Opening SOUL.\n';
  String? metadata;
  Object? metadataError;
  Map<String, dynamic>? listing;
  Map<String, dynamic> Function(Map<String, dynamic>)? corruptResponse;
  Object? soulWriteError;
  bool malformedAck = false;
  Completer<void>? authentication;
  final authenticationEntered = Completer<void>();
  void Function()? afterDescriptionAck;
  final reads = <(String, Map<String, String>)>[];
  final writes = <(String, Map<String, dynamic>)>[];
  late final repository = ProfileIdentityRepository(
    name: 'work',
    read: read,
    write: write,
  );

  Future<Map<String, dynamic>> read(
    String path,
    Map<String, String> query,
  ) async {
    reads.add((path, {...query}));
    switch (path) {
      case 'profiles':
        return {
          'profiles': [
            {'name': 'work', 'path': '/fixture/work'},
          ],
        };
      case 'profiles/active':
        return {'current': 'work', 'active': 'work'};
      case 'profiles/work/soul':
        return {'content': soul, 'exists': true};
      case 'files/read':
        expect(query, {'path': '/fixture/work/profile.yaml'});
        if (metadataError case final error?) throw error;
        final bytes = utf8.encode(
          metadata ?? 'description: ${jsonEncode(description)}\n',
        );
        final result = {
          'name': 'profile.yaml',
          'path': '/fixture/work/profile.yaml',
          'size': bytes.length,
          'mime_type': 'application/octet-stream',
          'data_url':
              'data:application/octet-stream;base64,${base64Encode(bytes)}',
        };
        return corruptResponse?.call(result) ?? result;
      case 'files':
        if (listing case final response?) return response;
        throw StateError('Directory unreadable');
      default:
        throw StateError('Unexpected endpoint');
    }
  }

  Future<Map<String, dynamic>> write(
    String method,
    String path,
    Map<String, String> query,
    Map<String, dynamic> body,
    bool Function() canDispatch,
    void Function() onDispatched,
  ) async {
    expect(method, 'PUT');
    expect(query, isEmpty);
    if (authentication != null && !authenticationEntered.isCompleted) {
      authenticationEntered.complete();
    }
    await authentication?.future;
    if (!canDispatch()) throw StateError('Retired before physical dispatch');
    onDispatched();
    writes.add((path, {...body}));
    if (malformedAck) return {'ok': true};
    if (path.endsWith('/description')) {
      description = body['description'] as String;
      afterDescriptionAck?.call();
      return {
        'ok': true,
        'description': description,
        'description_auto': false,
      };
    }
    if (soulWriteError case final error?) throw error;
    soul = body['content'] as String;
    return {'ok': true};
  }

  ProfileIdentityEditIntent intent(Map<ProfileIdentityField, String> wanted) =>
      ProfileIdentityEditIntent(
        baseline: const {
          descriptionField: 'Opening description',
          soulField: 'Opening SOUL.\n',
        },
        wanted: wanted,
      );

  Future<ProfileIdentitySaveResult> save(
    Map<ProfileIdentityField, String> wanted,
  ) => repository.save(
    intent(wanted),
    canDispatch: () => true,
    onDispatched: (_) {},
  );
}

void main() {
  test(
    'strict managed metadata and SOUL reads retain distinct normalization',
    () async {
      final host = _Host()..description = '  Role  ';
      final observation = await host.repository.load();
      expect(observation.values, {
        descriptionField: 'Role',
        soulField: 'Opening SOUL.\n',
      });
      expect(observation.issues, isEmpty);
      expect(host.reads.where((read) => read.$1 == 'profiles'), hasLength(1));
      expect(
        host.reads.any(
          (read) => read.$1.startsWith('fs/') || read.$2.containsKey('profile'),
        ),
        isFalse,
      );
    },
  );

  for (final yaml in [
    'description: null',
    'description: 7',
    '- description',
    'description: [broken',
  ]) {
    test('unreadable metadata remains independent of SOUL: $yaml', () async {
      final host = _Host()..metadata = yaml;
      final observation = await host.repository.load();
      expect(observation.values.containsKey(descriptionField), isFalse);
      expect(observation.issues.containsKey(descriptionField), isTrue);
      expect(observation.values[soulField], host.soul);
      final saved = await host.save({soulField: 'Exact SOUL.\n'});
      expect(
        saved.fields[soulField]!.disposition,
        ProfileIdentityWriteDisposition.confirmed,
      );
      expect(host.writes.single.$2, {'content': 'Exact SOUL.\n'});
    });
  }

  final corruptions =
      <String, Map<String, dynamic> Function(Map<String, dynamic>)>{
        'aliased path': (response) => {
          ...response,
          'path': '/other/profile.yaml',
        },
        'wrong name': (response) => {...response, 'name': 'other.yaml'},
        'wrong size': (response) => {...response, 'size': 1},
        'oversize': (response) => {...response, 'size': 65537},
        'invalid UTF8': (response) => {
          ...response,
          'size': 1,
          'data_url': 'data:application/octet-stream;base64,/w==',
        },
        'invalid base64': (response) => {
          ...response,
          'data_url': 'data:application/octet-stream;base64,!',
        },
      };
  for (final entry in corruptions.entries) {
    test('${entry.key} cannot become an empty Description write', () async {
      final host = _Host()..corruptResponse = entry.value;
      final saved = await host.save({descriptionField: ''});
      expect(
        saved.fields[descriptionField]!.disposition,
        ProfileIdentityWriteDisposition.unavailable,
      );
      expect(host.writes, isEmpty);
    });
  }

  test('404 alone cannot establish an empty Description', () async {
    final host = _Host()
      ..metadataError = const DashboardHttpException(404, 'Missing');
    final observation = await host.repository.load();
    expect(observation.issues.containsKey(descriptionField), isTrue);
    expect(observation.values.containsKey(descriptionField), isFalse);
  });

  test(
    'successful exact parent listing establishes observed metadata absence',
    () async {
      final host = _Host()
        ..metadataError = const DashboardHttpException(404, 'Missing')
        ..listing = {
          'path': '/fixture/work',
          'entries': [
            {'name': 'SOUL.md'},
          ],
        };
      final observation = await host.repository.load();
      expect(observation.values[descriptionField], '');
    },
  );

  for (final entries in [
    [
      {'name': 'profile.yaml'},
    ],
    [
      {'name': ''},
    ],
    [
      {'name': '../profile.yaml'},
    ],
    [
      {'name': 'SOUL.md'},
      {'name': 'SOUL.md'},
    ],
  ]) {
    test(
      'invalid or present metadata listing cannot prove absence: $entries',
      () async {
        final host = _Host()
          ..metadataError = const DashboardHttpException(404, 'Missing')
          ..listing = {'path': '/fixture/work', 'entries': entries};
        final observation = await host.repository.load();
        expect(observation.issues.containsKey(descriptionField), isTrue);
      },
    );
  }

  test('same-field conflict sends no PUT and retains server text', () async {
    final host = _Host()..description = 'Changed elsewhere';
    final saved = await host.save({descriptionField: 'My edit'});
    expect(
      saved.fields[descriptionField]!.disposition,
      ProfileIdentityWriteDisposition.conflict,
    );
    expect(saved.fields[descriptionField]!.value, 'Changed elsewhere');
    expect(host.writes, isEmpty);
  });

  test('converged text sends no PUT and does not invent an ACK', () async {
    final host = _Host()..description = 'Desired';
    final saved = await host.save({descriptionField: '  Desired  '});
    expect(
      saved.fields[descriptionField]!.disposition,
      ProfileIdentityWriteDisposition.converged,
    );
    expect(saved.hasConfirmedChanges, isFalse);
    expect(host.writes, isEmpty);
  });

  test(
    'SOUL whitespace and intentional empty Description survive sparse writes',
    () async {
      final host = _Host();
      final saved = await host.save({
        descriptionField: '',
        soulField: '  Exact.\n\n',
      });
      expect(
        saved.fields.values.every(
          (field) =>
              field.disposition == ProfileIdentityWriteDisposition.confirmed,
        ),
        isTrue,
      );
      expect(host.writes.map((write) => write.$2), [
        {'description': ''},
        {'content': '  Exact.\n\n'},
      ]);
    },
  );

  test(
    'second-field lost ACK does not erase confirmed Description or replay',
    () async {
      final host = _Host()..soulWriteError = StateError('Lost ACK');
      final saved = await host.save({
        descriptionField: 'Saved',
        soulField: 'Pending',
      });
      expect(
        saved.fields[descriptionField]!.disposition,
        ProfileIdentityWriteDisposition.confirmed,
      );
      expect(
        saved.fields[soulField]!.disposition,
        ProfileIdentityWriteDisposition.uncertain,
      );
      expect(host.writes, hasLength(2));
    },
  );

  test(
    'second-field explicit HTTP rejection stays distinct from uncertain delivery',
    () async {
      final host = _Host()
        ..soulWriteError = const DashboardHttpException(403, 'Forbidden');
      final saved = await host.save({
        descriptionField: 'Saved',
        soulField: 'Pending',
      });
      expect(
        saved.fields[descriptionField]!.disposition,
        ProfileIdentityWriteDisposition.confirmed,
      );
      expect(
        saved.fields[soulField]!.disposition,
        ProfileIdentityWriteDisposition.rejected,
      );
    },
  );

  test('retirement during authentication admits neither field', () async {
    final host = _Host()..authentication = Completer<void>();
    var active = true;
    final pending = host.repository.save(
      host.intent({descriptionField: 'Pending', soulField: 'Pending'}),
      canDispatch: () => active,
      onDispatched: (_) => fail('Retired write was dispatched'),
    );
    await host.authenticationEntered.future;
    active = false;
    host.authentication!.complete();
    final saved = await pending;
    expect(host.writes, isEmpty);
    expect(
      saved.fields.values.every(
        (field) => field.disposition == ProfileIdentityWriteDisposition.notSent,
      ),
      isTrue,
    );
  });

  test(
    'retirement after first ACK preserves it and forbids the second dispatch',
    () async {
      final host = _Host();
      var active = true;
      host.afterDescriptionAck = () => active = false;
      final saved = await host.repository.save(
        host.intent({descriptionField: 'Saved', soulField: 'Pending'}),
        canDispatch: () => active,
        onDispatched: (_) {},
      );
      expect(
        saved.fields[descriptionField]!.disposition,
        ProfileIdentityWriteDisposition.confirmed,
      );
      expect(
        saved.fields[soulField]!.disposition,
        ProfileIdentityWriteDisposition.notSent,
      );
      expect(host.writes, hasLength(1));
    },
  );

  test(
    'leading SOUL BOM blocks that field while Description remains usable',
    () async {
      final host = _Host();
      final saved = await host.save({
        descriptionField: 'Saved',
        soulField: '\uFEFFExact',
      });
      expect(
        saved.fields[descriptionField]!.disposition,
        ProfileIdentityWriteDisposition.confirmed,
      );
      expect(
        saved.fields[soulField]!.disposition,
        ProfileIdentityWriteDisposition.unavailable,
      );
      expect(host.writes, hasLength(1));
    },
  );
}
