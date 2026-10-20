/// Synthetic examples copied from contract §4.1-4.3. No real data.
const porterExampleA = r'''{"v": 1, "notice_id": "n-3f2a9c1b7d4e", "created": "2026-10-19T09:05:02.000Z", "mode": "trial",
 "kind": "items", "level": "red", "title": "🔴 Birk wartet auf dich",
 "lines": ["Antwort an Galerie Ostwind freigeben?", "Jemand wartet auf Antwort"],
 "items": [{"item_id": "2026-10/0a1b2c3d4e5f", "session_id": "s-ostwind", "profile": "birk",
            "block": "new", "line": "Antwort an Galerie Ostwind freigeben?",
            "why": "Jemand wartet auf Antwort", "snooze_label": null}],
 "actions": [{"id": "open", "label": "Öffnen"}, {"id": "snooze", "label": "Später", "default": "default"},
             {"id": "rate", "value": "unwichtig", "label": "unwichtig"},
             {"id": "rate", "value": "so_lala", "label": "so lala"},
             {"id": "rate", "value": "sehr_wichtig", "label": "sehr wichtig"}],
 "open_profile": "pforte", "feedback": {"rating": null, "snoozed_until": null, "opened": false}}''';

const porterExampleB = r'''{"v": 1, "notice_id": "n-9e8d7c6b5a41", "created": "2026-10-20T06:05:03.000Z", "mode": "live",
 "kind": "items", "level": "red", "title": "🔴 3 Dinge warten",
 "lines": ["⏰ Zurückgestellt: Buchhandlung Seewind: Lesungstermin bestätigen?", "Frist heute"],
 "items": [{"item_id": "2026-10/1b2c3d4e5f60", "session_id": "s-seewind", "profile": "birk",
            "block": "snoozed", "line": "Buchhandlung Seewind: Lesungstermin bestätigen?",
            "why": "Frist heute", "snooze_label": "zurückgestellt gestern 15:10 · 2× zurückgestellt"},
           {"item_id": "2026-10/2c3d4e5f6071", "session_id": "s-steuer", "profile": "birk",
            "block": "new", "line": "Steuer: Konto für Erstattung bestätigen?",
            "why": "Frist morgen", "snooze_label": null},
           {"item_id": "2026-10/3d4e5f607182", "session_id": "s-notiz", "profile": "cothinker",
            "block": "new", "line": "Zugangsdaten im Klartext in Notiz gefunden: löschen?",
            "why": "Sicherheitsrisiko", "snooze_label": null}],
 "actions": [{"id": "open", "label": "Öffnen"}, {"id": "snooze", "label": "Später", "default": "default"}],
 "open_profile": "pforte", "feedback": {"rating": null, "snoozed_until": null, "opened": false}}''';

const porterExampleC = r'''{"v": 1, "notice_id": "n-5a4b3c2d1e0f", "created": "2026-11-08T10:05:01.000Z", "mode": "live",
 "kind": "trial_end", "level": "green", "title": "🟢 Probelauf beendet",
 "lines": ["Probelauf beendet, ab jetzt höchstens 3 am Tag"],
 "items": [],
 "actions": [{"id": "open", "label": "Öffnen"}, {"id": "snooze", "label": "Später", "default": "default"}],
 "open_profile": "pforte", "feedback": {"rating": null, "snoozed_until": null, "opened": false}}''';

const porterNoticeIds = ['n-3f2a9c1b7d4e', 'n-9e8d7c6b5a41', 'n-5a4b3c2d1e0f'];
const porterExamples = [porterExampleA, porterExampleB, porterExampleC];
