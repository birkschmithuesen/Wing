# Wing reports its own client source: conversation mode by default in Wing

Card: `t_9d9bcf31` (board `wing`), "[Plan] Wing Voice: Client erkennen (Wing != Mac-Desktop) -> Gespraechsmodus als
Standard in Wing". Status: design, no production code.

Verified on 2026-10-13 against:

- Wing `voice-offline` @ `eb87b9b028ca38846bfd20e598ae181ede9c919d`
- hermes-agent live tree `birk-local` @ `69723ab76730ce4b780597f18be9f9f74d886010`
- hermes-agent upstream `origin/main` @ `63d0b94120027d487c9a5235b9ec64b696af1b26`. Between `origin/main` and
  `birk-local`, these files have no relevant hunks: `agent/system_prompt.py`, `agent/surface_switch.py`,
  `agent/session_source.py`, `agent/tool_guardrails.py`, `agent/conversation_loop.py`, `agent/coding_context.py`,
  `agent/terminal_approval_batch.py`, `gateway/session_context.py`, `tui_gateway/methods_session.py`,
  `tui_gateway/server.py`, `tui_gateway/session_lifecycle.py`, `tui_gateway/session_reaper.py`,
  `tui_gateway/session_workdir.py`, `tui_gateway/ws.py`, `tui_gateway/entry.py`,
  `tui_gateway/contracts/sessions.py`. Checked with `git diff --stat origin/main HEAD -- <files>`: only
  `system_prompt.py`, `methods_session.py`, `server.py` and `session_workdir.py` differ, and only in unrelated
  hunks (async handoff guidance, cwd repair).

## 1. Goal

Birk's rule, in skill `voice-conversational-mode` (lines 8 and 13):

- Wing on the phone uses conversation mode. Wing reads the reply aloud itself, so the reply is plain text in spoken
  style, with no Markdown and no `text_to_speech`.
- The desktop app on the Mac stays in normal typing style.
- Telegram already gets its own mode via `platform_hints.telegram.append`
  (`/home/birk/.hermes/profiles/birk/config.yaml:1078-1080`).

The default applies per client, not per dictated turn. A per-turn voice marker (option C) is **gestrichen,
Folgekarte**.

## 2. Verified facts (the card's premises, checked)

| # | Card claim | Result | Evidence |
|---|---|---|---|
| F1 | Wing creates sessions with `source: 'desktop'` | **confirmed** | `lib/core/services/profile_gateway.dart:535` (in `createSession`, 528-541) |
| F2 | In state.db Wing and Mac sessions cannot be told apart, and `origin_json` is empty | **confirmed** | profile `birk` `state.db`: 208 rows with `source='desktop'`, all with `origin_json` NULL or empty |
| F3 | The platform hint comes from the source, with config `platform_hints.<platform>` append/replace | **confirmed, refined** | The hint is keyed by `agent.platform` (`agent/system_prompt.py:445-456`), which equals the session source (`tui_gateway/server.py:1571-1578`, `_resolve_agent_platform`). The override lives in `agent/system_prompt.py:55-68`, loaded at `agent/agent_init.py:1432` from top-level config `platform_hints`. An unknown platform gets `""` as its default hint (`system_prompt.py:413-425`), and append/replace still apply to it. |
| F4 | Four desktop-dependent paths | **refuted as too small: there are at least 11** | Table in section 4 |
| F5 | The Wing session list uses `sessionVisibility.includes(row['source'])` | **confirmed** | `lib/core/models/session_visibility.dart:7-23`. Only `cron, tool, subagent, kanban, oneshot` are hidden, so `wing` is visible. |

Further facts that drive the design:

- **F6. An explicit source passes through unchanged.** `session.create` calls `_new_runtime_ids(params)`, which
  calls `_resolve_session_source(explicit)` (`tui_gateway/methods_session.py:65-67`, `server.py:1571-1574`). No
  core code checks the value against a list.
- **F7. Unknown params are rejected.** Params models use `extra="forbid"` (`tui_gateway/contracts/base.py:16`).
  `validate_params` answers error `4000` for an unknown key (`tui_gateway/contracts/registry.py:95-110`). So on
  stock Hermes, a new field such as `client: "wing"` on `session.create` makes session creation **fail**.
  `SessionCreateParams` is defined at `tui_gateway/contracts/sessions.py:119-140`.
- **F8. No pass-through field exists.** `session.create` reads only the fields listed in F7, and `title` goes to
  the DB title. `prompt.submit` `surface` is a closed set `{"hud","voice-live"}` (`methods_prompt.py:732,780`).
  `origin_json` has exactly one writer, `run_agent.py:57` `_gateway_origin_json`, which runs only when the agent
  has a messaging identity.
- **F9. Resume re-derives the source from the resume params, not from the row.** See `_Resume.mint` (calls
  `_new_runtime_ids(self.params)`, `methods_session.py:639-644`) and `SessionResumeParams.source`
  (`contracts/sessions.py:187`). Wing resumes without a source (`profile_gateway.dart:543-551`), so the live
  platform falls back to the gateway's environment. Birk's dashboard process has no `HERMES_DESKTOP`, so resumed
  Wing sessions run today as platform **`tui`**. Evidence: 36 user rows in `state.db` carry the surface-switch
  note "now being answered on a different interface: tui".
- **F10. Hermes already switches surfaces per turn.** A resumed session keeps its stored prompt. If the current
  `agent.platform` differs from the prompt's `Platform:` trailer, the current platform's hint is delivered as a
  turn note (`agent/surface_switch.py:103-140`, tested in `tests/agent/test_system_prompt_restore.py:99-170`).
- **F11. The gateway greets every socket with `gateway.ready`** (`tui_gateway/ws.py:365-369`,
  `tui_gateway/entry.py:310-314`, contract `tui_gateway/contracts/events.py:51-61`). Wing waits for that frame
  on every socket and gets it back from `WsClient.waitForGatewayReady()` (`lib/core/services/ws_client.dart:577-590`,
  awaited in `profile_gateway.dart`, inside `_forDashboard.open()`). Wing sends `client.capabilities` as a
  notification, so it never reads that method's result (`ws_client.dart:266-273`).
- **F12. System prompts are stored outside `sessions`.** They live in table `system_prompts(hash, prompt)`,
  joined via `sessions.system_prompt_hash`; `sessions.system_prompt` is NULL on new rows. The server has no
  `sqlite3` CLI, so checks use `python3 -c "import sqlite3 …"`.

## 3. Decision

**Option A, gated by capability.** Wing reports `source: "wing"`, and the core treats `wing` like `desktop`
everywhere except the platform hint and the desktop-only client tools.

1. **Core (Birk's fork, one `feat/*` branch, additive):**
   - Add `DESKTOP_LIKE_SOURCES = frozenset({"desktop", "wing"})` and `WING_SOURCE = "wing"` in
     `agent/session_source.py`.
   - Replace the `== "desktop"` checks listed in section 4 ("parity: yes") with membership in that set.
   - Advertise support in `gateway.ready` with a new optional payload field
     `session_sources: list[str] | None = None`, set to `["wing"]` in both emitters, and regenerate the contract
     artefacts.
2. **Wing (this repo):**
   - `ProfileGateway` reads the `gateway.ready` frame on every socket open.
   - If `payload.session_sources` contains `"wing"`, it sends `source: "wing"` on `session.create` **and**
     `session.resume`.
   - Otherwise it sends exactly what it sends today: `source: "desktop"` on create and no source on resume.
3. **Config (profile `birk`):** add `platform_hints.wing.append` with the conversation-mode instruction
   (section 6).
4. **Per-client behaviour comes from F10 for free:**
   - A Mac-created session opened in Wing gets the Wing hint as a turn note.
   - A Wing-created session opened on the Mac gets the desktop hint back.

   This is exactly "Standard je Client".

### Why

- **Upstream compatibility of Wing.** Against any gateway that does not advertise `session_sources`, Wing's wire
  traffic is byte-identical to today's. That covers stock upstream Hermes and Birk's server before the core feat
  is deployed. No `4000`, no degraded paths.
- **Smallest core diff that breaks nothing.** It is one constant plus about 11 one-line membership changes, all
  behaviour-neutral for every existing source. The platform hint itself needs **no** core code, because unknown
  platforms already honour `platform_hints.<name>` (F3).
- **Reversible.** Remove the config entry and the hint is gone. Drop the feat line from `features.txt` and the
  gateway stops advertising, so Wing falls back to `desktop` on its own.
- **State.db recognisability is native.** `sessions.source = 'wing'` and `created_source = 'wing'`.

### Rejected alternatives

| Alternative | Why rejected (evidence) |
|---|---|
| **B. Keep `desktop` and add a field such as `client: "wing"`** | Stock gateways reject it with `4000` (F7), so it would need retry logic. No existing field reaches the prompt or `origin_json` (F8), so the core diff is larger: new contract field, session dict, agent attribute, hint lookup, persistence (`origin_json` is read by gateway recovery, `gateway/session_recovery.py:128-133`) and resume restore. It also loses F10's per-client switching, because the platform stays `desktop`, so Mac and Wing would share one surface. |
| **A without core parity (Wing sends `wing`, core unchanged)** | It degrades about 10 paths (section 4). Two of them: automatic reaps end the row on every phone reconnect (`session_lifecycle.py:363-366`), and orphan rows are never swept (`session_reaper.py:390`). The card forbids that. |
| **A without capability gating** | It would put the same degradations on every unmodified gateway. That breaks Wing's upstream contract. |
| **Config only: `platform_hints.desktop.append`** | It changes the Mac desktop app too, which contradicts Birk's rule (skill line 13). |
| **A separate Hermes profile for Wing** | It splits memory, skills and the session list from profile `birk`. |
| **C. Per-turn voice marker** | **gestrichen, Folgekarte.** The default is per client (card). |
| **Reading the `client.capabilities` result for negotiation** | Wing sends that method as a notification and never reads its reply (F11). Turning it into a request would touch connection setup ordering in `ws_client.dart`. `gateway.ready` is already awaited per socket. |

### AGENTS.md tension (recorded, not silently resolved)

`AGENTS.md` scopes Wing to unmodified upstream Hermes and calls backend patches out of scope. The stock API cannot
tell Wing from the Mac. F7 and F8 show that every client-only route either breaks session creation on stock Hermes
or changes the Mac too.

- The card explicitly asks for an additive core change under the fork workflow (skill `hermes-core-fork-workflow`).
  That change is a separate deliverable in Birk's hermes-agent fork, not in Wing.
- The Wing part keeps the AGENTS.md contract: against unmodified upstream Hermes it changes nothing on the wire.

## 4. Core sites keyed on `desktop` (audit, birk-local @ 69723ab)

"Parity: yes" means the site moves to `in DESKTOP_LIKE_SOURCES`, so `wing` behaves exactly like `desktop`. Today
new Wing sessions run as `desktop`.

| # | Site | With `wing`, unpatched | Parity |
|---|---|---|---|
| 1 | `tui_gateway/session_lifecycle.py:77` `track_liveness=… == "desktop"` | Lenient lease, single release try | yes |
| 2 | `tui_gateway/session_lifecycle.py:363-364` `_desktop_automatic_cleanup` | Each automatic reap (`ws_disconnect`, `idle_timeout`, …) ends the DB row | yes |
| 3 | `tui_gateway/session_reaper.py:390` `_ORPHAN_SWEEP_SOURCES` | Startup orphan sweep never closes wing rows | yes (add `"wing"`) |
| 4 | `hermes_state_maintenance.py:156` default `sources` | Same, for the maintenance sweep | yes (add `"wing"`) |
| 5 | `tui_gateway/session_workdir.py:219` `_LAUNCH_CWD_NOT_A_WORKSPACE` | Gateway launch dir persisted as the chat workspace | yes |
| 6 | `tui_gateway/session_workdir.py:247` `source == "desktop"` | `cwd_explicit` host-invisible paths dropped | yes |
| 7 | `tui_gateway/methods_session.py:968` `model_history_only` | Full hydration although Wing pages over REST | yes |
| 8 | `agent/tool_guardrails.py:85` `_ATTENDED_PLATFORMS` | Treated as unattended: hard stops after repeated failures | yes |
| 9 | `agent/conversation_loop.py:728` `platform not in ("desktop","tui")` | No between-turn toolset refresh | yes |
| 10 | `agent/session_source.py:16` `UI_TRANSPORT_SOURCES` (feeds `ATTENDED_SOURCES`) | One-shot children inherit `wing`; free-tier waits | yes |
| 11 | `agent/coding_context.py:30` `INTERACTIVE_CODING_PLATFORMS` | Never adopts the coding posture | yes |
| 12 | `gateway/session_context.py:185-188` `NON_MESSAGING_SESSION_SURFACES` | Counted as a messaging surface (`verify_on_stop: auto` off) | yes (literal `"wing"`, since this module is the leaf that `session_source` imports) |
| 13 | `agent/terminal_approval_batch.py:293` `!= "desktop"` | Sequential approvals instead of one batch | yes (new Wing sessions get batching today) |
| 14 | `tui_gateway/server.py:1985` `CLIENT_SURFACE_TOOLSETS` fold-in | Only `project`, no `desktop_ui` / `catalog` | **no**: Wing cannot serve `desktop_preview`, `focus_pane`, and so on |
| 15 | `toolsets.py:146-155` setup/start_chat/catalog gated to `desktop` | Removed | **no** (desktop onboarding UI) |
| 16 | `agent/inline_tool_executors.py:223`, `agent/initiate_setup_prompt.py:88,103`, `tools/connectors/gateway/client.py:267` | Desktop cards, setup prelude, `return_to=hermes-desktop` | **no** (desktop app only) |
| 17 | `agent/system_prompt.py` `platform_hint` | `""` + `platform_hints.wing` | **no**: this is the feature |
| 18 | `agent/turn_recovery_autorecover.py:37` `_STOP_HINTS` | "send /stop to cancel" | no (cosmetic, correct for Wing) |

Toolsets are unaffected. `_load_enabled_toolsets` always reads the `cli` key of `platform_toolsets`
(`tui_gateway/server.py:2049-2091`), so `wing` loses no tools. The session listings `session.list`,
`session.most_recent` and REST `/api/sessions` only deny `kanban, tool, oneshot` (plus `unknown` for
most-recent), so wing rows are listed.

Known cosmetic limitation (not fixed here): the Mac desktop app does not know `wing`. Its sidebar
(`apps/desktop/src/lib/session-source.ts:49`) shows wing rows as an unknown messaging platform. Changing it needs a
desktop app build and is a Folgekarte.

## 5. Wing design

- **New file `lib/core/services/wing_session_source.dart`:**
  - `const wingSessionSource = 'wing'`
  - `const desktopSessionSource = 'desktop'`
  - `bool gatewayAdvertisesWingSource(Map<String, dynamic> readyFrame)`, which is true only when
    `frame.params.payload.session_sources` is a `List` containing `'wing'`. Any other shape returns false
    (fail closed to today's behaviour).
- **`ProfileGateway`** (`lib/core/services/profile_gateway.dart`):
  - Public field `bool wingSourceAdvertised = false`, assigned in `_forDashboard.open()` from the frame that
    `candidate.waitForGatewayReady()` returns, on every successful open (true **and** false, so a reconnect to an
    older gateway resets it).
  - `String get sessionSource => wingSourceAdvertised ? wingSessionSource : desktopSessionSource;`
  - `createSession` sends `'source': sessionSource`.
  - `resume` adds `'source': wingSessionSource` only when `wingSourceAdvertised`, using the null-aware map entry
    style already used in `createSession`.
  - `branch` is unchanged; the core copies the live parent's source.
- **`ProfileWorkspaceController`** (`profile_workspace_controller.dart:2577`): the optimistic
  `ProfileChat.source` uses `resource.gateway.sessionSource` instead of the literal `'desktop'`. `_hydrate`
  already overwrites it from `info.source` (`:6831-6833`).
- **Not touched:**
  - VoiceCapture, `voice_input_controller.dart`, `profile_workspace_screen.dart` (VAD chain, card `t_24ef9c3d`)
  - The legacy `WsClient.createSession` / `resumeSession` / `createOrResumeSession` used by
    `DesktopGatewayClient` (`desktop_gateway_client.dart:211,220`). That path sends no source today and is
    outside the profile workspace.
- **No UI change.** There are no new controls, labels or status messages, so the Studio design charter has no
  surface here.

## 6. Config

In `/home/birk/.hermes/profiles/birk/config.yaml`, insert **only** the two `wing:` lines directly after the
telegram `append:` line (line 1080 at review time, under `platform_hints:` at line 1078). Do not touch the
`telegram` entry: its value stays byte-identical to whatever the file holds.

```yaml
platform_hints:
  telegram:
    # (unchanged — keep the existing append line exactly as it is)
  wing:
    append: "Standard Wing (Handy-App): Gesprächsmodus (Skill voice-conversational-mode, Abschnitt Ausgabekanal je Client). Wing liest deine Antwort selbst vor: Plain Text im Gesprächsstil, kein Markdown, keine Listen, keine Pfade, kein text_to_speech."
```

The telegram value is not quoted here on purpose. The 2026-10-13 review quoted a longer text,
`Standardmodus Telegram: … Tippt Birk lange Textnachrichten oder sagt 'Text', antworte als Text.`. The file read
during review correction held
`Standard Telegram: Gesprächsmodus mit Sprachnachrichten (Skill voice-conversational-mode).`. The file is
authoritative, and the edit must leave it unchanged (plan Task D1 checks this before and after).

It takes effect only after a gateway restart, which only Birk runs, in a separate shell. Then update skill
`voice-conversational-mode` line 13: "Wing meldet sich als `wing` (seit Karte t_9d9bcf31); der Hinweis kommt über
`platform_hints.wing`". This replaces the "nicht unterscheidbar" sentence.

## 7. Data flow

```
Wing ProfileGateway.open()
  └─ waitForGatewayReady() → payload.session_sources == ["wing"] ?  ──no──► create: source=desktop, resume: (none)   [today]
                                                                     └─yes─► create/resume: source=wing
tui_gateway session.create/resume → session["source"]="wing" → AIAgent.platform="wing"
  ├─ new session: prompt = … ("" default hint + platform_hints.wing.append) … "Platform: wing" → system_prompts
  ├─ resumed Mac session (Platform: desktop): stored prompt kept + turn note with the wing hint (surface_switch)
  └─ DESKTOP_LIKE_SOURCES: lifecycle, reaper, workdir, guardrails … behave as for desktop
Mac desktop app: source=desktop (HERMES_DESKTOP) → no wing hint; on a Wing-created session the turn note restores the desktop hint
```

## 8. Error handling

- **Missing advertisement, malformed payload or older gateway:** Wing falls back to `desktop`, which is today's
  behaviour.
- **Gateway restarts with a different build mid-session:** the next socket open re-reads `gateway.ready`, and the
  next resume uses the new verdict.
- **Config entry missing:** a Wing session has an empty platform hint. That is harmless; the surface-switch note
  then points at the prompt's own interface section.

## 9. Testing and acceptance

| Acceptance (card) | Proof |
|---|---|
| New Wing session recognisable in `state.db` | Live: Wing creates a chat, then `sessions.source='wing'` and `created_source='wing'` (python3 sqlite query in the plan) |
| Wing session prompt contains the hint and a Mac desktop prompt does not (one test that checks both) | Core pytest `tests/agent/test_platform_hint_wing.py`: builds the stable prompt for `platform="wing"` and `platform="desktop"` with the same `platform_hints.wing` override, asserts presence and absence, and checks both surface-switch directions. Live: the newest wing row's `system_prompts.prompt` contains `Standard Wing (Handy-App)`, and the newest Mac desktop row's does not. |
| The existing Wing session list still shows all sessions | Wing test: `SessionVisibility.chats.includes('wing')`, and a list with `desktop`+`wing` rows shows both. Live: Wing's chat list before and after shows the same sessions plus the new one. |
| Installed on the phone | Plan task: CI APK, then `wing-voice-build.sh`, then 2-MB chunks, then `pm install -r`, then check the version |
| Gateway restart by Birk only | Plan marks the restart as Birk's step in a separate shell |

The core parity tests in `tests/tui_gateway/test_wing_session_source.py` assert, for each "parity: yes" site in
section 4, that `wing` gives the same answer as `desktop`. Sites 14-17 are asserted to stay desktop-only, and
`gateway.ready` is checked to advertise `session_sources == ["wing"]`.

## 10. Sequencing

Wing implementation starts only after the VAD chain (`t_24ef9c3d`) is merged into `voice-offline` by `t_145c5731`
(Birk, 13.10.). As of `wt/t_24ef9c3d` today, the VAD diff touches no file of this design. The VAD plan's later
tasks touch `voice_preferences.dart`, `android_voice.dart`, `voice_input_controller.dart`,
`voice_preferences_card.dart` and `profile_workspace_screen.dart`, and none of them overlaps. Core tasks do not
depend on the VAD merge and may run first. Wing then works against either gateway.

## 11. Open points (ANNAHME)

- ANNAHME: the dashboard's WebSocket sidecar emits `gateway.ready` from `tui_gateway/ws.py` (not from `entry.py`).
  Wing connects to `:9119` (process `hermes -p birk dashboard`). Check: after deployment, Wing debug or a
  WebSocket probe shows `session_sources` in the ready payload. Both emitters are patched anyway.
- ANNAHME: Wing renders batched terminal approvals (site 13), because new Wing sessions already run as `desktop`
  and get batching today. Check: in a Wing session, trigger two parallel terminal commands that need approval and
  confirm that the approval sheet appears.
