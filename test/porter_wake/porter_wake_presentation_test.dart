import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/porter_wake/porter_wake_notice.dart';
import 'package:wing/porter_wake/porter_wake_presentation.dart';

import 'porter_wake_fixtures.dart';

PorterNotificationSpec spec(String raw) => PorterNotificationSpec.fromNotice(
  'conn-1',
  PorterNotice.fromJson(jsonDecode(raw) as Map<String, dynamic>),
);

void main() {
  test('a trial notice gives Später plus three ratings and an open tap', () {
    final s = spec(porterExampleA);
    expect(s.buttons.map((b) => b.label), ['Später', 'unwichtig', 'so lala', 'sehr wichtig']);
    expect(s.buttons.map((b) => b.feedbackBody), [
      {'action': 'snooze', 'value': 'default'},
      {'action': 'rate', 'value': 'unwichtig'},
      {'action': 'rate', 'value': 'so_lala'},
      {'action': 'rate', 'value': 'sehr_wichtig'},
    ]);
    expect(s.toJson()['tap'], 'open');
  });

  test('a live notice gives only Später and an open tap', () {
    final s = spec(porterExampleB);
    expect(s.buttons.map((b) => b.label), ['Später']);
    expect(s.toJson()['tap'], 'open');
  });

  test('text is the server text: title, line 1, expanded line 1 + line 2', () {
    final a = spec(porterExampleA);
    expect(a.title, '🔴 Birk wartet auf dich');
    expect(a.body, 'Antwort an Galerie Ostwind freigeben?');
    expect(a.expanded, 'Antwort an Galerie Ostwind freigeben?\nJemand wartet auf Antwort');
    final c = spec(porterExampleC);
    expect(c.expanded, 'Probelauf beendet, ab jetzt höchstens 3 am Tag');
  });

  test('the neutral notice has no buttons', () {
    final n = PorterNotificationSpec.neutral('conn-1', 'n-3f2a9c1b7d4e');
    expect(n.title, 'Pforte: neue Nachricht');
    expect(n.buttons, isEmpty);
    expect(n.neutral, isTrue);
    expect(n.toJson()['tap'], 'open');
  });

  test('every spec uses the one porter slot on the attention channel', () {
    final json = spec(porterExampleB).toJson();
    expect(json['id'], 214700);
    expect(json['channel'], 'wing_attention_notifications');
    expect(json['connection'], 'conn-1');
    expect(json['notice_id'], 'n-9e8d7c6b5a41');
    expect(json['open_profile'], 'pforte');
  });
}
