import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/administration_logs.dart';
import 'package:wing/core/services/administration_logs_session.dart';
import 'support/administration_fixture.dart';

void main() {
  late AdministrationFixture fixture;
  late AdministrationLogsSession session;

  setUp(() {
    fixture = AdministrationFixture();
    session = AdministrationLogsSession(fixture.server);
  });
  tearDown(() {
    session.dispose();
    fixture.server.close();
  });

  test('a newer submitted query owns a held older log read', () async {
    final older = Completer<Map<String, dynamic>>();
    fixture.override = (method, path, query, body) async {
      expect(method, 'GET');
      expect(path, 'logs');
      expect(body, isNull);
      expect(query.containsKey('profile'), isFalse);
      if (query['file'] == 'agent') return older.future;
      return {
        'file': query['file'],
        'lines': ['ERROR Current log'],
      };
    };
    final pending = session.refresh();
    await session.selectFile(AdministrationLogFile.errors);
    await session.selectLevel(AdministrationLogLevel.error);
    await session.search('  Timeout  ');
    expect(fixture.requests.last.$3, {
      'file': 'errors',
      'lines': '100',
      'level': 'ERROR',
      'search': '  Timeout  ',
    });
    final accepted = session.state;
    expect(accepted.snapshot!.lines, ['ERROR Current log']);
    older.complete({
      'file': 'agent',
      'lines': [7],
    });
    await pending;
    expect(session.state, same(accepted));
    expect(session.state.loading, isFalse);
    expect(session.state.error, isNull);
  });

  test(
    'published log lines cannot be changed by source or reader mutation',
    () async {
      final lines = ['Original log'];
      fixture.override = (_, _, _, _) async => {
        'file': 'agent',
        'lines': lines,
      };
      await session.refresh();
      final accepted = session.state.snapshot!;
      lines.add('Later alias mutation');
      expect(accepted.lines, ['Original log']);
      expect(() => accepted.lines.clear(), throwsUnsupportedError);
    },
  );

  test('wrong-file data is rejected and a valid refresh recovers', () async {
    var returnedFile = 'agent';
    fixture.override = (_, _, _, _) async => {
      'file': returnedFile,
      'lines': [],
    };
    await session.refresh();
    expect(session.state.snapshot, isNotNull);
    returnedFile = 'gateway';
    await session.refresh();
    expect(session.state.snapshot, isNull);
    expect(session.state.error, 'The server returned an invalid response.');
    expect(session.state.canRecoverRead, isFalse);
    returnedFile = 'agent';
    await session.refresh();
    expect(session.state.snapshot!.lines, isEmpty);
    expect(session.state.error, isNull);
  });

  test(
    'retiring from the pending observation prevents an unsent read',
    () async {
      session.addListener(session.dispose);
      await session.refresh();
      expect(fixture.requests, isEmpty);
    },
  );

  test('a held read publishes nothing after retirement', () async {
    final response = Completer<Map<String, dynamic>>();
    fixture.override = (_, _, _, _) => response.future;
    var publications = 0;
    session.addListener(() => publications++);
    final pending = session.refresh();
    expect(fixture.requests.single.$3, {'file': 'agent', 'lines': '100'});
    final before = publications;
    session.dispose();
    response.complete({
      'file': 'agent',
      'lines': ['Late result'],
    });
    await pending;
    expect(publications, before);
  });

  test('a retired log session cannot dispatch another search', () async {
    session.dispose();
    await session.search('No dispatch');
    expect(fixture.requests, isEmpty);
  });

  test(
    'retiring a consumer leaves its borrowed repository available',
    () async {
      session.dispose();
      fixture.override = (_, _, _, _) async => {'file': 'gateway', 'lines': []};
      final next = AdministrationLogsSession(fixture.server);
      addTearDown(next.dispose);
      await next.selectFile(AdministrationLogFile.gateway);
      expect(next.state.snapshot!.lines, isEmpty);
    },
  );
}
