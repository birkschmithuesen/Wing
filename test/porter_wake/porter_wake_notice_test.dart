import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/porter_wake/porter_wake_notice.dart';

import 'porter_wake_fixtures.dart';

PorterNotice parse(String raw) =>
    PorterNotice.fromJson(jsonDecode(raw) as Map<String, dynamic>);

void main() {
  test('example A parses', () {
    final n = parse(porterExampleA);
    expect(n.noticeId, 'n-3f2a9c1b7d4e');
    expect(n.isTrial, isTrue);
    expect(n.title, '🔴 Birk wartet auf dich');
    expect(n.lines, [
      'Antwort an Galerie Ostwind freigeben?',
      'Jemand wartet auf Antwort',
    ]);
    expect(n.items.single.sessionId, 's-ostwind');
    expect(n.actions.map((a) => a.id), ['open', 'snooze', 'rate', 'rate', 'rate']);
    expect(n.actions[1].defaultValue, 'default');
    expect(n.actions.skip(2).map((a) => a.value),
        ['unwichtig', 'so_lala', 'sehr_wichtig']);
    expect(n.openProfile, 'pforte');
    expect(n.feedback.rating, isNull);
    expect(n.feedback.opened, isFalse);
  });

  test('example B parses with the snoozed block first', () {
    final n = parse(porterExampleB);
    expect(n.isTrial, isFalse);
    expect(n.items.map((i) => i.block), ['snoozed', 'new', 'new']);
    expect(n.items.first.snoozeLabel,
        'zurückgestellt gestern 15:10 · 2× zurückgestellt');
    expect(n.items[1].snoozeLabel, isNull);
    expect(n.lines.first, startsWith('⏰ Zurückgestellt: '));
    expect(n.actions.map((a) => a.id), ['open', 'snooze']);
  });

  test('example C parses with no items', () {
    final n = parse(porterExampleC);
    expect(n.kind, 'trial_end');
    expect(n.items, isEmpty);
    expect(n.lines, ['Probelauf beendet, ab jetzt höchstens 3 am Tag']);
  });

  test('unknown fields and unknown action ids are ignored', () {
    final data = jsonDecode(porterExampleA) as Map<String, dynamic>
      ..['future_field'] = {'x': 1}
      ..['kind'] = 'brand_new_kind';
    (data['actions'] as List).add({'id': 'teleport', 'label': 'X'});
    (data['items'] as List).first['extra'] = true;
    final n = PorterNotice.fromJson(data);
    expect(n.kind, 'brand_new_kind');
    expect(n.actions.map((a) => a.id), isNot(contains('teleport')));
    expect(n.items, hasLength(1));
  });

  test('a notice without title or lines is malformed', () {
    final data = jsonDecode(porterExampleC) as Map<String, dynamic>
      ..remove('title');
    expect(() => PorterNotice.fromJson(data), throwsFormatException);
    final noLines = jsonDecode(porterExampleC) as Map<String, dynamic>
      ..['lines'] = 'x';
    expect(() => PorterNotice.fromJson(noLines), throwsFormatException);
  });
}
