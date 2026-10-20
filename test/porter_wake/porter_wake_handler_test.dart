import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/porter_wake/porter_wake_api.dart';
import 'package:wing/porter_wake/porter_wake_bridge.dart';
import 'package:wing/porter_wake/porter_wake_handler.dart';
import 'package:wing/porter_wake/porter_wake_ledger.dart';

import 'fake_porter_bridge.dart';
import 'porter_wake_fake_server.dart';

List<int> push(String type, int v, String id) =>
    utf8.encode(jsonEncode({'v': v, 'type': type, 'notice_id': id}));

void main() {
  late FakePorterServer server;
  late RecordingPorterWakeBridge bridge;
  late PorterWakeHandler handler;
  final opened = <(String, String)>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    server = FakePorterServer();
    bridge = RecordingPorterWakeBridge();
    opened.clear();
    handler = PorterWakeHandler(
      bridge: bridge,
      ledger: PorterNoticeLedger(await SharedPreferences.getInstance()),
      apiFor: (_) async => PorterWakeApi(server.client()),
      openProfile: (connection, profile) async => opened.add((connection, profile)),
    );
  });

  List<String> noticeFetches() => [
    for (final r in server.porterRequests())
      if (r.method == 'GET' && r.url.path.contains('/notices/')) r.url.path,
  ];

  test('a v1 porter_wake push fetches the notice exactly once', () async {
    await handler.onPush('conn-1', push('porter_wake', 1, 'n-3f2a9c1b7d4e'));
    expect(noticeFetches(), ['${FakePorterServer.base}/notices/n-3f2a9c1b7d4e']);
    expect(bridge.shown.single.title, '🔴 Birk wartet auf dich');
  });

  test('an unknown push type fetches nothing and does not throw', () async {
    await handler.onPush('conn-1', push('other', 1, 'n-3f2a9c1b7d4e'));
    expect(server.requests, isEmpty);
    expect(bridge.shown, isEmpty);
  });

  test('a v2 push fetches nothing and does not throw', () async {
    await handler.onPush('conn-1', push('porter_wake', 2, 'n-3f2a9c1b7d4e'));
    expect(server.requests, isEmpty);
    expect(bridge.shown, isEmpty);
  });

  test('a second push with the same notice id shows nothing and posts nothing', () async {
    await handler.onPush('conn-1', push('porter_wake', 1, 'n-3f2a9c1b7d4e'));
    await handler.onPush('conn-1', push('porter_wake', 1, 'n-3f2a9c1b7d4e'));
    expect(bridge.shown, hasLength(1));
    expect(noticeFetches(), hasLength(1));
    expect(server.porterRequests().where((r) => r.method == 'POST'), isEmpty);
  });

  test('a failed fetch shows the neutral notice with only the open tap', () async {
    for (final status in [404, 500]) {
      bridge.shown.clear();
      server.statusFor['GET ${FakePorterServer.base}/notices/n-9e8d7c6b5a41'] = status;
      await (await SharedPreferences.getInstance()).clear();
      await handler.onPush('conn-1', push('porter_wake', 1, 'n-9e8d7c6b5a41'));
      final shown = bridge.shown.single;
      expect(shown.neutral, isTrue, reason: '$status');
      expect(shown.title, 'Pforte: neue Nachricht');
      expect(shown.buttons, isEmpty);
      expect(shown.title, isNot(contains('n-9e8d7c6b5a41')));
    }
  });

  test('each button posts the exact feedback body', () async {
    for (final (action, value) in [
      ('snooze', 'default'),
      ('rate', 'unwichtig'),
      ('rate', 'so_lala'),
      ('rate', 'sehr_wichtig'),
    ]) {
      expect(
        await handler.onInteraction(PorterInteractionEvent(
          connectionId: 'conn-1', noticeId: 'n-3f2a9c1b7d4e', action: action,
          value: value, openProfile: 'pforte', neutral: false)),
        isTrue,
      );
      final post = server.porterRequests().last;
      expect(post.url.path, '${FakePorterServer.base}/notices/n-3f2a9c1b7d4e/feedback');
      expect(jsonDecode(post.body), {'action': action, 'value': value});
    }
    expect(bridge.cancels, 4);
  });

  test('applied false is a success and dismisses the notification', () async {
    server.bodyFor['POST ${FakePorterServer.base}/notices/n-3f2a9c1b7d4e/feedback'] =
        {'notice_id': 'n-3f2a9c1b7d4e', 'action': 'rate', 'applied': false, 'result': {'rating': 'so_lala'}};
    final ok = await handler.onInteraction(const PorterInteractionEvent(
      connectionId: 'conn-1', noticeId: 'n-3f2a9c1b7d4e', action: 'rate',
      value: 'unwichtig', openProfile: 'pforte', neutral: false));
    expect(ok, isTrue);
    expect(bridge.cancels, 1);
  });

  test('a failed feedback keeps the notification', () async {
    server.statusFor['POST ${FakePorterServer.base}/notices/n-3f2a9c1b7d4e/feedback'] = 500;
    final ok = await handler.onInteraction(const PorterInteractionEvent(
      connectionId: 'conn-1', noticeId: 'n-3f2a9c1b7d4e', action: 'snooze',
      value: 'default', openProfile: 'pforte', neutral: false));
    expect(ok, isFalse);
    expect(bridge.cancels, 0);
  });

  test('open posts {"action":"open"}, dismisses and opens the profile', () async {
    await handler.onInteraction(const PorterInteractionEvent(
      connectionId: 'conn-1', noticeId: 'n-3f2a9c1b7d4e', action: 'open',
      openProfile: 'pforte', neutral: false));
    expect(jsonDecode(server.porterRequests().last.body), {'action': 'open'});
    expect(bridge.cancels, 1);
    expect(opened, [('conn-1', 'pforte')]);
  });

  test('opening the neutral notice retries the fetch first', () async {
    await handler.onInteraction(const PorterInteractionEvent(
      connectionId: 'conn-1', noticeId: 'n-9e8d7c6b5a41', action: 'open',
      openProfile: 'pforte', neutral: true));
    expect(noticeFetches(), ['${FakePorterServer.base}/notices/n-9e8d7c6b5a41']);
    expect(jsonDecode(server.porterRequests().last.body), {'action': 'open'});
    expect(opened, [('conn-1', 'pforte')]);
  });

  test('a push for an unknown connection shows the neutral notice', () async {
    final h = PorterWakeHandler(
      bridge: bridge,
      ledger: PorterNoticeLedger(await SharedPreferences.getInstance()),
      apiFor: (_) async => null,
    );
    await h.onPush('gone', push('porter_wake', 1, 'n-5a4b3c2d1e0f'));
    expect(bridge.shown.single.neutral, isTrue);
  });
}
