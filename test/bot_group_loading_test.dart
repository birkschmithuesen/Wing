import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/bot_group_read_state.dart';
import 'package:wing/core/services/bot_group_session.dart';
import 'package:wing/core/services/bots_preferences.dart';
import 'package:wing/core/models/operational_error.dart';
import 'support/bots_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BotsFixture fixture;
  late BotGroupSession session;
  late List<OperationalErrorObservation> incidents;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    fixture = BotsFixture();
    incidents = [];
    final group = (await readFixtureGroups(
      fixture.repository,
      groupMessages: null,
    )).single;
    session = BotGroupSession(
      fixture.repository,
      group,
      appearances: FixedGroupAppearances(const []),
      reads: BotGroupReadState(),
      groupMessages: null,
      preferences: await BotsPreferences.load(),
      onOperationalError: incidents.add,
    );
  });
  tearDown(() => session.dispose());

  test('group initial loading lasts through the first log read', () async {
    final log = Completer<Map<String, dynamic>?>();
    fixture.readHook = (_, method, _) async =>
        method == 'groups.log' ? log.future : null;
    final reading = session.reading;
    final opening = session.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(session.runtime, isNotNull);
    expect(session.loading, isTrue);
    expect(reading.historyAvailable, isFalse);
    log.complete(null);
    await opening;
    expect(session.loading, isFalse);
    expect(
      reading.historyAvailable,
      isTrue,
      reason: 'A successful empty log is known content',
    );
  });

  test(
    'failed initial log stays unavailable and retry remains loading',
    () async {
      var fail = true;
      final log = Completer<Map<String, dynamic>?>();
      fixture.readHook = (_, method, _) async {
        if (method != 'groups.log') return null;
        if (fail) throw StateError('Offline');
        return log.future;
      };
      await session.refresh();
      expect(session.reading.historyAvailable, isFalse);
      expect(session.error, isNotNull);
      expect(incidents.last.error, contains('Group updates could not refresh'));
      final operation = incidents.last.operation;
      expect(
        incidents.last.connectionIdentity,
        session.group.scope.connectionIdentity,
      );
      fail = false;
      final retrying = session.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(session.loading, isTrue);
      log.complete(null);
      await retrying;
      expect(session.reading.historyAvailable, isTrue);
      expect(session.error, isNull);
      expect(incidents.last.operation, operation);
      expect(incidents.last.error, isNull);
    },
  );

  test('known empty group stays quiet through a held automatic read', () async {
    await session.refresh();
    final log = Completer<Map<String, dynamic>?>();
    fixture.readHook = (_, method, _) async =>
        method == 'groups.log' ? log.future : null;
    final refreshing = session.refresh(explicit: false);
    await Future<void>.delayed(Duration.zero);
    expect(session.loading, isFalse);
    expect(session.reading.historyAvailable, isTrue);
    log.completeError(StateError('Offline'));
    await refreshing;
    expect(session.reading.historyAvailable, isTrue);
    expect(session.error, isNull);
    expect(incidents.last.error, contains('Group updates could not refresh'));
  });
}
