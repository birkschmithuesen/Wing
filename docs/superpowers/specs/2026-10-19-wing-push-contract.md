# Wing push contract (Pforte W4): server ↔ Wing interface

> Verbatim copy. Source: PB repo branch `wt/t_2b45a583` @ `4ad631ba`, file last changed in `9c73d2cf`
> (`docs/superpowers/specs/2026-10-19-wing-push-contract.md`). Copied 2026-10-19 for Wing card
> t_7737d2c2. Do not edit here; changes go to the PB original (section 10). Wing-side corrections of
> stale `WING/…:line` references live in `docs/superpowers/plans/2026-10-19-wing-porter-push.md`.

Card t_2b45a583 (plan card). This document is the interface the Wing repo builds against. A
separate plan card on board `wing` plans the Wing side; this document plans nothing in Wing.

Paths: `PB` = `/mnt/HC_Volume_106183673/hermes/profiles/birk` (server repo), `CH` =
`/mnt/HC_Volume_106183673/hermes/profiles/pforte`, `WING` = `/mnt/HC_Volume_106183673/projekte/wing`
(branch `voice-offline`; every `WING/…:line` reference below was read on 2026-10-19).

Sources of truth on the server side:
- Design: `docs/superpowers/specs/2026-10-15-porter-wake-design.md` (sections 5.7-5.11, 9).
- Build: `docs/superpowers/plans/2026-10-15-porter-wake.md`.
- ntfy server: `docs/superpowers/plans/2026-10-19-ntfy-server.md`.

## 1. Scope and parties

| Party | Role |
|---|---|
| Porter wake gate (`CH/scripts/porter_wake_gate.py`, hourly) | Decides, stores ONE notice per run, publishes a content-free push per registered device. |
| ntfy server `http://100.75.24.33:2586` (tailnet only) | Carries the push to the phone. Deny-all auth; the gate publishes with a token. |
| ntfy Android app (F-Droid; the phone runs microG, no Google) | UnifiedPush distributor. Holds the connection to the ntfy server and hands each push to Wing. |
| Wing (Android, Flutter) | UnifiedPush client. Fetches the notice over its authenticated dashboard connection, shows it, and sends feedback. Has the „Nachtruhe“ settings screen. |
| Birk dashboard `http://100.75.24.33:9119` (tailnet, gated auth) | Hosts the porter wake API under `/api/plugins/porter_wake`. |

Contract boundaries:
- The push carries no content.
- Every text Birk reads is rendered on the server. Wing never builds titles or lines itself.
- Quiet hours, the cap, bundling and trial/live mode live only on the server. Wing-side
  suppression is rejected (Birk, decision c).
- Wing never edits a config file. It only calls the endpoints in section 3.

## 2. Wing module isolation

`WING/AGENTS.md:3-11` says Wing targets unmodified upstream Hermes and that "Backend patches,
forks, plugins and custom endpoints are out of scope." The porter wake API is a custom plugin
endpoint, so it conflicts with that rule. Birk's decision (c) of 2026-10-19 stands, and the
conflict is contained:

1. **One module.** All porter wake code lives in one optional Wing module (suggested
   `lib/features/porter_wake/`). No other Wing code imports porter-specific types; the module
   plugs in through existing seams: the dashboard client, the notification sink and the settings
   screen.
2. **Inert on stock Hermes.** At connection time Wing calls `GET /api/plugins/porter_wake/settings/quiet-hours`.
   - 404 means the plugin is absent or not enabled on that server. Wing then registers no
     UnifiedPush endpoint, hides „Nachtruhe“ and never calls another porter route for that
     connection.
   - 401 means the session expired. Re-login through the existing flow, then retry once.
3. **Recorded exception.** The Wing plan card records this as an explicit exception to
   `WING/AGENTS.md:3-11`, approved by Birk on 2026-10-19 for this module only.
4. **Privacy docs.** These must change on the Wing side, which is the Wing plan's job. Both
   say today that Wing sends no push tokens:
   - `WING/PRIVACY.md:25` ("Wing does not use Firebase or transmit device push tokens to a push provider").
   - `WING/docs/PLAY_DATA_SAFETY.md:23` ("Wing does not register with a push provider or transmit device push tokens").

   The new text: Wing registers a UnifiedPush endpoint with the user's own Hermes server; the
   distributor is the user's own ntfy app; still no Firebase.

## 3. Endpoints

### 3.1 Base, auth and errors

- **Base:** `http://100.75.24.33:9119/api/plugins/porter_wake` (the birk dashboard, tailnet bind).
- **Auth:** the dashboard's gated auth, the same as every other dashboard call Wing makes.
  Wing's `DashboardClient` logs in with `POST /auth/password-login`
  `{"provider":"basic","username","password"}`. The response sets the `hermes_session_at`
  cookie, which Wing sends as `Cookie` (`WING/lib/core/services/connection_manager.dart:1359-1395`,
  `_authHeaders` `:1424-1449`).
- **Client helpers:** the REST helpers prepend `$_baseUrl/api/`, so Wing calls
  `apiGet('plugins/porter_wake/notices/<id>')`. Helpers already exist for all four methods:
  `apiGet` `:1500`, `apiPost` `:1592`, `apiDelete`/`apiDeleteResult` `:1624-1632`,
  `apiPut` `:1674`. No new auth code is needed.
- **No other credentials:** no new header, token or secret exists for these routes.
- **Bodies:** requests and responses are JSON, `Content-Type: application/json`, UTF-8.
- **Timestamps:** ISO 8601 UTC with milliseconds and `Z` (`2026-10-19T06:05:02.000Z`), unless
  a field says otherwise.

| Status | Meaning |
|---|---|
| 200 | Success; body as listed. |
| 400 | `{"error": "<English reason>"}`: validation failed; nothing changed. |
| 401 | From the dashboard auth: not logged in. Re-login and retry once. |
| 404 | Plugin not enabled (any route, body set by the dashboard), or `{"error": "unknown notice"}`. |
| 409 | `{"error": "…"}`: a conflict (device limit, config layout not editable). |
| 503 | `{"error": "wake config missing"}`: the server has no valid `wake` block. Treat it like 404 for the session. |

The server handlers are `plugins/porter/wake_api.py`, and the FastAPI router is
`plugins/porter_wake/dashboard/plugin_api.py`. Both are produced by PB plan Task 17.

### 3.2 Push devices

**`POST /push/devices`** registers or replaces a UnifiedPush endpoint.

```json
{"device_id": "wing-7f3c2a9e41d84b07", "endpoint": "http://100.75.24.33:2586/upAbC123xyz?up=1", "label": "Pixel 7"}
```

| Field | Rule |
|---|---|
| `device_id` | Required, `[A-Za-z0-9_-]{8,64}`. Stable per Wing install, created once and kept in `flutter_secure_storage` (already a dependency, `WING/pubspec.yaml:23`). |
| `endpoint` | Required. Must start with the server's configured `wake.ntfy.base_url` + `/`. The path is one topic `up[A-Za-z0-9_-]{6,64}`. The only allowed query is `up=1`. |
| `label` | Optional, ≤ 40 characters, shown in `GET /push/devices`. |

- **200** `{"device_id": "wing-7f3c2a9e41d84b07", "registered": "2026-10-19T06:00:00.000Z", "replaced": false}`.
  `replaced: true` means the device id existed and its endpoint was swapped (endpoint rotation).
- **400** for a bad id, a foreign host, a bad topic or an extra query.
- **409** `{"error": "too many devices"}` for a NEW id once `max_devices` (5) exist.

**`DELETE /push/devices/{device_id}`** → 200 `{"device_id": "…", "removed": true}`. It is
idempotent: an unknown id returns `"removed": false`, still with 200.

**`GET /push/devices`** → 200:

```json
{"devices": [{"device_id": "wing-7f3c2a9e41d84b07", "label": "Pixel 7", "registered": "2026-10-19T06:00:00.000Z", "endpoint_host": "100.75.24.33:2586"}]}
```

The full endpoint URL is never returned, because the topic is a capability.

### 3.3 Notices

**`GET /notices/{notice_id}`**, where `notice_id` matches `n-[0-9a-f]{12}`.
- 200: the notice JSON (section 4).
- 404 `{"error": "unknown notice"}`.

The notice is rendered when it is fetched, so `feedback` reflects the current state.

**`POST /notices/{notice_id}/feedback`** takes one of three bodies:

```json
{"action": "rate",   "value": "unwichtig"}
{"action": "snooze", "value": "default"}
{"action": "open"}
```

| Action | `value` | Result |
|---|---|---|
| `rate` | `unwichtig` \| `so_lala` \| `sehr_wichtig` | `{"rating": "so_lala"}` |
| `snooze` | `default` \| `morgen` \| `<n>h` (n = 1-72) \| ISO 8601 datetime WITH offset | `{"until": "<ISO UTC>", "items": [{"item_id": "2026-10/0123456789ab", "count": 1}]}` |
| `open` | none | `{}` |

Response 200:

```json
{"notice_id": "n-3f2a9c1b7d4e", "action": "snooze", "applied": true,
 "result": {"until": "2026-10-20T06:00:00.000Z", "items": [{"item_id": "2026-10/0123456789ab", "count": 1}]}}
```

- **Idempotent per `notice_id` + `action`:** the first call applies and returns `applied: true`.
  Every repeat returns `applied: false` with the FIRST result unchanged. Wing may retry freely.
- **Snooze rules:**
  - `default` and `morgen` both mean the next end of quiet hours.
  - A target inside quiet hours is moved to the end of quiet hours by the server; the
    response carries the effective `until`.
  - A target in the past answers 400.
  - The snooze applies to every item of the notice.
- **Rating:** accepted in any mode, but only trial notices show the rate actions. One rating per
  notice; the first rating wins.
- **A snooze is not a rating.**
- 400 for an unknown action or a bad value; 404 for an unknown notice.

### 3.4 Quiet hours („Nachtruhe“)

**`GET /settings/quiet-hours`** → 200:

```json
{"enabled": true, "from": "22:00", "to": "08:00", "timezone": "Europe/Berlin"}
```

**`PUT /settings/quiet-hours`** takes:

```json
{"enabled": false, "from": "22:00", "to": "07:30"}
```

- All three fields are required.
- `from` and `to` are `HH:MM` (00:00-23:59), and `from != to` when `enabled` is true.
- A window may wrap midnight.
- `timezone` is read-only; a body that contains it answers 400.

Responses:
- **200**: the same shape as GET, re-read from the file after the write.
- **400**: validation failed.
- **409** `{"error": "config layout not editable"}`: someone reshaped the block by hand.
- **503**: the `wake` block is missing.

The server writes `plugins.entries.porter.settings.wake.quiet_hours` in `CH/config.yaml`
atomically and keeps the rest of the file byte-for-byte. The gate reads it on its next run.

## 4. Notice JSON

`GET /notices/{id}` returns this object, produced by `wake_notice.render`
(PB plan Task 5, Task 17):

| Field | Type | Rule |
|---|---|---|
| `v` | int | `1`. |
| `notice_id` | string | `n-[0-9a-f]{12}`. |
| `created` | string | ISO UTC. |
| `mode` | string | `trial` \| `live`. |
| `kind` | string | `items` \| `trial_end` \| `trial_report`. |
| `level` | string | `red` \| `yellow` \| `green`. |
| `title` | string | ≤ 40 characters. Starts with the level emoji (🔴 🟡 🟢). Never ids, paths or hashes. |
| `lines` | string[] | Each ≤ 80 characters. `lines[0]` is the question in plain German. `lines[1]` (why now) is present only with a concrete reason. Never ids, paths or hashes. |
| `items` | object[] | `{item_id, session_id, profile, block: "new"\|"snoozed", line, why, snooze_label}`. Snoozed items come first. `why` and `snooze_label` may be `null`. Empty for `trial_end` and `trial_report`. |
| `actions` | object[] | See below. |
| `open_profile` | string | `"pforte"`. |
| `feedback` | object | `{"rating": null\|"<value>", "snoozed_until": null\|"<ISO UTC>", "opened": bool}`. |

`actions`, in this order:
- always `{"id":"open","label":"Öffnen"}` and `{"id":"snooze","label":"Später","default":"default"}`;
- only when `mode` is `trial` and `kind` is `items`, also
  `{"id":"rate","value":"unwichtig","label":"unwichtig"}`,
  `{"id":"rate","value":"so_lala","label":"so lala"}` and
  `{"id":"rate","value":"sehr_wichtig","label":"sehr wichtig"}`.

Wing shows the labels as given and sends `id` (and `value`) back as the feedback `action`/`value`.

Title forms (German, Birk reads them):

| Case | Title |
|---|---|
| One new item | „🔴 CoThinker wartet auf dich“ (profile display name) |
| Several, at least one new | „🔴 3 Dinge warten“ |
| Snoozed items only | „🟡 2 Dinge warten“ |
| `trial_end` | „🟢 Probelauf beendet“ |
| `trial_report` | „🟡 Probelauf: Zahlen“ |

- **Snoozed block:** in a bundle with snoozed items, `lines[0]` is „⏰ Zurückgestellt: <question>“.
- **`snooze_label`:** „zurückgestellt gestern 15:10“, plus „ · 2× zurückgestellt“ from the second snooze on.
- **Unknown fields:** Wing ignores them, and new fields are only ever added (section 10).

### 4.1 Example A: single urgent item, trial mode (screenshot 1)

```json
{"v": 1, "notice_id": "n-3f2a9c1b7d4e", "created": "2026-10-19T09:05:02.000Z", "mode": "trial",
 "kind": "items", "level": "red", "title": "🔴 Birk wartet auf dich",
 "lines": ["Antwort an Galerie Ostwind freigeben?", "Jemand wartet auf Antwort"],
 "items": [{"item_id": "2026-10/0a1b2c3d4e5f", "session_id": "s-ostwind", "profile": "birk",
            "block": "new", "line": "Antwort an Galerie Ostwind freigeben?",
            "why": "Jemand wartet auf Antwort", "snooze_label": null}],
 "actions": [{"id": "open", "label": "Öffnen"}, {"id": "snooze", "label": "Später", "default": "default"},
             {"id": "rate", "value": "unwichtig", "label": "unwichtig"},
             {"id": "rate", "value": "so_lala", "label": "so lala"},
             {"id": "rate", "value": "sehr_wichtig", "label": "sehr wichtig"}],
 "open_profile": "pforte", "feedback": {"rating": null, "snoozed_until": null, "opened": false}}
```

### 4.2 Example B: morning bundle with a snoozed block, live mode (screenshot 2)

```json
{"v": 1, "notice_id": "n-9e8d7c6b5a41", "created": "2026-10-20T06:05:03.000Z", "mode": "live",
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
 "open_profile": "pforte", "feedback": {"rating": null, "snoozed_until": null, "opened": false}}
```

### 4.3 Example C: trial ended (screenshot 3)

```json
{"v": 1, "notice_id": "n-5a4b3c2d1e0f", "created": "2026-11-08T10:05:01.000Z", "mode": "live",
 "kind": "trial_end", "level": "green", "title": "🟢 Probelauf beendet",
 "lines": ["Probelauf beendet, ab jetzt höchstens 3 am Tag"],
 "items": [],
 "actions": [{"id": "open", "label": "Öffnen"}, {"id": "snooze", "label": "Später", "default": "default"}],
 "open_profile": "pforte", "feedback": {"rating": null, "snoozed_until": null, "opened": false}}
```

## 5. Push

### 5.1 UnifiedPush registration

1. **Connector.** Wing adds a UnifiedPush connector library; the Wing plan picks it (for example
   the `unifiedpush` Flutter package). Today `WING/pubspec.yaml` has no push package; the only
   notification package is `flutter_local_notifications` (`:41`).
2. **Distributor.** The ntfy Android app is the distributor. In the ntfy app, Birk sets the default
   server to `http://100.75.24.33:2586` and logs in with the phone's read-only ntfy user. Both
   happen at GO-LIVE of plan `2026-10-19-ntfy-server.md`.
3. **First register.** Wing registers with the distributor once the porter module is active
   (section 2, point 2). It receives an endpoint like
   `http://100.75.24.33:2586/upAbC123xyz?up=1`.
4. **Report to the server.** Wing POSTs the endpoint to `/push/devices` (section 3.2), with its
   stable `device_id` and an optional label (the device model).
5. **Endpoint change** (a new endpoint callback): POST again with the same `device_id`. The server
   replaces the endpoint.
6. **Revocation:** when Wing unregisters, the porter module is switched off, the connection is
   removed or the user logs out, Wing calls `DELETE /push/devices/{device_id}`. Birk can also
   remove a device on the server (`GET` lists them).
7. **Storage.** The server keeps devices in `CH/porter/push-devices.json` (mode 0600). Only the
   gate publishes to them, and the topic is never returned.

### 5.2 Payload (content-free)

For each registered device, the gate POSTs exactly these bytes to the endpoint, with
`Authorization: Bearer <publisher token>` and `Content-Type: application/json`:

```json
{"v":1,"type":"porter_wake","notice_id":"n-3f2a9c1b7d4e"}
```

- No title, message, tags, click or attachment headers.
- No item, profile, session or text data.
- At most one push per gate run.

Wing MUST:
- parse the body as UTF-8 JSON;
- ignore a body whose `type` is not `porter_wake`, or whose `v` is greater than 1, without
  crashing; it may log the event locally, without the payload;
- treat `notice_id` as opaque and only use it in the URL of section 3.3.

The publisher is `plugins/porter/wake_push.py` `NtfyChannel` (PB plan Task 9).

## 6. Wing behaviour on push

1. **Fetch.** On a `porter_wake` message, Wing calls `GET /notices/{notice_id}`, with re-login
   on 401.
2. **Show.** Wing shows the notice on the existing **attention** channel:
   - Dart: `TurnNotificationService.attentionChannel`, id `wing_attention_notifications`
     (`WING/lib/core/services/turn_notification_service.dart:333-338`).
   - Native: `ChatNotifications.kt:30`, created with `IMPORTANCE_HIGH` at `:141`.
   - Content title = `title`; text = `lines[0]`; expanded text = `lines[0]` + newline + `lines[1]`
     when present.
   - One notice replaces any earlier porter notice; at most one porter notification is visible.
3. **Actions.** Every action in `actions` must be reachable from the notification.
   - **Live:** tap = „Öffnen“, plus the button „Später“.
   - **Trial:** tap = „Öffnen“, plus buttons „Später“, „unwichtig“, „so lala“ and „sehr wichtig“.
     Standard Android shows at most 3 action buttons. Wing's approval notification already
     solves this with a custom RemoteViews layout of up to 4 buttons
     (`WING/android/app/src/main/kotlin/com/tarkilhk/wing/ChatNotifications.kt:173-211`, buttons
     at `:208-211`). The porter notification follows that precedent with 4 buttons; „Öffnen“ is
     the tap.
4. **Specific snooze times.** „in 2 Stunden“ (`2h`) and „morgen“ (`morgen`) are offered in the
   expanded view or an in-app sheet reached by long-press on the item in Wing. A plain „Später“
   sends `default`.
5. **Button results.** A rate or snooze button sends the feedback (section 3.3) and then dismisses
   the notification. `applied: false` is a success, not an error.
6. **„Öffnen“.** Wing sends `{"action":"open"}`, then opens or refreshes the Pforte chat:
   profile `open_profile` (`pforte`), using the pinned or most recent pforte chat. Use the
   existing path:
   - `openProfileNotification(payload)` (`WING/lib/main.dart:174-216`), via
     `ProfileWorkspaceController.openNotification` (`profile_workspace_controller.dart:1086`) or
     `openSession` (`:2667`);
   - the payload key is `ProfileSessionKey` `{connection, connection_identity, profile, session}`
     (`:49-76`).

   An item tap inside Wing's notice view may open the item's own session (`profile`,
   `session_id`).
7. **Fetch failure** (network, 5xx, 404): Wing shows a neutral local notification
   „Pforte: neue Nachricht“ with „Öffnen“ only, and retries the fetch when it is opened. Wing
   never shows content from the push payload; it has none.
8. **Duplicates.** A second push with the same `notice_id` must not create a second notification
   or a second feedback call.

## 7. Settings screen „Nachtruhe“

- **Location:** a new block or section in `WING/lib/core/screens/app_settings_content.dart`, next
  to the Notifications section (`_SettingsSection(title: 'Notifications', …)` at `:227-228`,
  toggles via `CompactSwitchListTile` at `:232-257`). It is shown only while the porter module is
  active (section 2).
- **Controls:** a switch „Nachtruhe“ (`enabled`), plus two time pickers „von“ (`from`) and „bis“
  (`to`), and the server's `timezone` as read-only text.
- **Load:** `GET /settings/quiet-hours` when the screen opens. The server is the only truth: Wing
  stores no copy as a source of truth (no `saveDevicePreference` for these values).
- **Save:**
  - Each change sends `PUT /settings/quiet-hours` with all three fields, and the screen shows the
    200 response.
  - On 400 or 409, show the server's `error` text and revert to the last server state.
  - On 401, re-login and retry once.
- **Not in Wing:** the daily cap and the trial/live mode. They are server config only (decision d).

## 8. Acceptance for the Wing side

A stranger can check each item. Secrets are never typed into a command line: they are read with
`read -s` into a shell variable in the stranger's own terminal.

### 8.1 Server reachable (prerequisite, needs PB GO-LIVE done)

```bash
read -r -p "dashboard user: " U
read -r -s -p "dashboard password: " P
curl -s -c /tmp/wing-contract.jar -H 'Content-Type: application/json' \
  -d "{\"provider\":\"basic\",\"username\":\"$U\",\"password\":\"$P\"}" \
  http://100.75.24.33:9119/auth/password-login -o /dev/null -w '%{http_code}\n'
curl -s -b /tmp/wing-contract.jar http://100.75.24.33:9119/api/plugins/porter_wake/settings/quiet-hours
```

Expected:
- the login prints `200`;
- the GET prints `{"enabled": true, "from": "22:00", "to": "08:00", "timezone": "Europe/Berlin"}`
  (or Birk's current values);
- without `-b`, the GET gives 401.

Afterwards run `rm /tmp/wing-contract.jar`.

### 8.2 Wing unit tests (in WING, names chosen by the Wing plan)

Run: `flutter test test/porter_wake_*_test.dart`. Expected: all pass, covering at least:
- **Payload:** `porter_wake` with `v: 1` triggers exactly one fetch; an unknown `type` or `v: 2`
  triggers none and no crash.
- **Notice parsing:** examples A, B and C (section 4) parse; unknown fields are ignored.
- **Actions:** trial notices give 4 buttons plus tap; live notices give 1 button plus tap.
  Every button posts the exact body of section 3.3, and `applied: false` counts as success.
- **Isolation:** a 404 from the quiet-hours probe disables the module: no UnifiedPush
  registration and no „Nachtruhe“ screen.
- **„Nachtruhe“:** shows the GET values; a PUT error reverts and shows the error text.
- **Fetch failure:** shows „Pforte: neue Nachricht“ with only „Öffnen“.

Also run: `flutter analyze --fatal-infos`. Expected: no issues (`WING/CONTRIBUTING.md` gate).

### 8.3 Test build on the phone

Use the chain in `WING/docs/superpowers/plans/2026-10-13-wing-voice-vad-input.md:4090-4112`:
1. `bash tools/factory/dispatch-check.sh voice-apk.yml publish=true`
2. `bash /home/birk/hermes-shared/hermes-entities/tools/technik/wing-voice-build.sh`
3. `hadb install /home/birk/handy-builds/wing-voice/wing-voice-latest.apk`
   (or the tailnet HTTP fallback described there).

Expected: `Success`, and a newer `lastUpdateTime` in
`hadb shell 'dumpsys package com.tarkilhk.wing.voice | grep lastUpdateTime'`.

### 8.4 End-to-end on the phone

1. **Registration.** Open Wing on the pforte-enabled connection, then on the server run
   `curl -s -b /tmp/wing-contract.jar http://100.75.24.33:9119/api/plugins/porter_wake/push/devices`.
   Expected: one device whose `endpoint_host` is `100.75.24.33:2586`.
2. **Forced push.** Use the PB GO-LIVE "forced fire" step of
   `docs/superpowers/plans/2026-10-15-porter-wake.md`. Expected: within about a minute, one
   attention notification with the server's title, and no second notification for the same
   `notice_id`.
3. **„Später“.** Expected: the notification disappears, and
   `GET /notices/<id>` shows `feedback.snoozed_until` set.
4. **Rating (trial).** Expected: `feedback.rating` is set, and a second tap changes nothing
   (`applied: false`).
5. **„Öffnen“.** Expected: the Pforte chat opens, and `feedback.opened` is `true`.
6. **„Nachtruhe“.** Change `bis` to 07:30 in Wing, then re-run the GET of 8.1. Expected:
   `"to": "07:30"`. Restore 08:00 afterwards.

### 8.5 Three-screenshot gate (go-live blocker)

From the Wing test build, take three screenshots of the rendered notification and show them to
Birk:
1. Example A (section 4.1): single urgent item, trial mode, with „Später“ and the three rating
   buttons.
2. Example B (section 4.2): morning bundle with the „⏰ Zurückgestellt“ block first.
3. Example C (section 4.3): „🟢 Probelauf beendet“.

How to produce them: serve the example notice JSONs from a local fake server, or force them
through the PB GO-LIVE. Capture with `hadb shell screencap -p /sdcard/porter-<n>.png` and pull the
file. Birk's OK on the three images is recorded on the Wing card and on t_2b45a583 before the
porter wake cron job goes live.

## 9. Server build mapping

| What Wing needs | Produced by |
|---|---|
| Notice rendering (title, lines, items, actions) | PB plan Task 5 (`plugins/porter/wake_notice.py`) |
| Push publisher (`NtfyChannel`), content-free payload, device registry | PB plan Task 9 (`plugins/porter/wake_push.py`) |
| Feedback semantics: rate, snooze, open, idempotency, snooze target rules | PB plan Task 11 (`plugins/porter/wake_feedback.py`) |
| Atomic quiet-hours write into `CH/config.yaml` | PB plan Task 12 (`plugins/porter/wake_config.py`) |
| Trial notices (`trial_end`, `trial_report`, rate actions) | PB plan Task 13 |
| Re-presentation of snoozed items, snoozed block | PB plan Task 14 |
| Every endpoint in section 3 (handlers and FastAPI router, plugin `porter_wake`) | PB plan Task 17 (`plugins/porter/wake_api.py`, `plugins/porter_wake/dashboard/plugin_api.py`) |
| ntfy server on `100.75.24.33:2586`, users and ACL, app as distributor | `docs/superpowers/plans/2026-10-19-ntfy-server.md` |
| Wing implementation | Separate plan card on board `wing` |

## 10. Versioning and change rules

- **`v`:** the payload `v` and the notice `v` are both 1. Adding an optional field is not a
  version change, and clients ignore unknown fields. Removing or renaming a field, or changing a
  meaning, raises `v`. The server then keeps serving `v: 1` until the Wing card confirms that the
  new version is supported.
- **Enumerations:** new `kind`, `level` or action `id` values may be added. Wing renders an unknown
  `kind` with its `title` and `lines`, and skips unknown actions.
- **Routes:** route paths are fixed. A new route is an addition and is listed here first.
- **Text:** the server owns all German text, and Wing must not rewrite it. A wording change needs
  no Wing release.
- **Change process:** every change to this contract is a reviewed commit to this file in PB,
  cross-linked on the Wing card.
