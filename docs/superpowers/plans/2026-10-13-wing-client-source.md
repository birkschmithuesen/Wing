# Wing client source ("wing") Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hermes recognises sessions created or resumed from Wing as source `wing` and gives them the
conversation-mode platform hint. The Mac desktop app keeps the normal style.

**Architecture:** The core (Birk's hermes-agent fork, one `feat/*` branch) gets one alias set,
`DESKTOP_LIKE_SOURCES = {"desktop","wing"}`, used at every site keyed on `desktop` that must keep its behaviour. It
also advertises `session_sources: ["wing"]` in `gateway.ready`. Wing sends `source: "wing"` on `session.create` and
`session.resume` only when the gateway advertises that; otherwise its wire traffic is unchanged. The hint itself is
plain config, `platform_hints.wing.append`. The core's existing surface switch (`agent/surface_switch.py`) then
makes the mode follow the client per turn.

**Tech Stack:**
- Python 3.14 (hermes-agent venv `/home/birk/.hermes/hermes-agent/venv`), pytest via `scripts/run_tests.sh`
- Flutter 3.44 / Dart 3.12: tests run only on GitHub Actions via `bash tools/factory/ci-suite.sh`

**Spec:** `docs/superpowers/specs/2026-10-13-wing-client-source-design.md`. Read sections 2 (facts), 3 (decision)
and 4 (site table) before any task.

## Basis / Rebase (do this before Task 1)

- **Wing tasks (W1-W2)** start only after the VAD chain is merged: card `t_24ef9c3d`, merged into `voice-offline`
  by card `t_145c5731` (Birk, 13.10., binding). Start the Wing branch from `voice-offline` **after** that merge.
  Check that the merge is in:
  `git log --oneline voice-offline | grep -i -m1 vad`. Expected: a merge or feat commit of the VAD chain. If
  there is no output, stop; the VAD chain is not merged yet.
- **Overlap with the VAD plan** (`docs/superpowers/plans/2026-10-13-wing-voice-vad-input.md`):
  - The VAD plan creates or modifies `lib/core/services/vad_endpoint.dart`, `voice_preferences.dart`,
    `android_voice.dart`, `lib/core/controllers/voice_input_controller.dart`, `voice_preferences_card.dart`,
    `vad_settings_section.dart`, `lib/core/screens/profile_workspace_screen.dart`, Kotlin under
    `android/app/src/main/kotlin/com/tarkilhk/wing/`, `.github/workflows/voice-apk.yml`, `docs/VOICE.md`,
    `docs/TESTING.md` and `docs/VAD_INPUT.md`.
  - This plan touches `lib/core/services/profile_gateway.dart`, `lib/core/services/profile_workspace_controller.dart`,
    the new `lib/core/services/wing_session_source.dart` and the new `test/wing_session_source_test.dart`.
  - **No overlapping file.** Do not touch any VAD file.
- **Re-verify every file:line cited here against the post-merge state** before W1:
  - `grep -n "'source': 'desktop'" lib/core/services/profile_gateway.dart`. Expected: one hit inside
    `createSession`, line 535 at plan time.
  - `grep -n "await candidate.waitForGatewayReady();" lib/core/services/profile_gateway.dart`. Expected: one hit in
    `_forDashboard`.
  - `grep -n "source: 'desktop'," lib/core/services/profile_workspace_controller.dart`. Expected: one hit, line 2577
    at plan time.

  If the line numbers moved, use the new ones. If the text no longer exists, stop and report.
- **Core tasks (C1-C3)** do not depend on the VAD merge and may run first. Re-verify the core citations before C1
  with the commands in C1 Step 1. The plan was verified against `birk-local` @ `69723ab76730` and `origin/main` @
  `63d0b94120027d48`.

## Global Constraints

- **Core repo** `/home/birk/.hermes/hermes-agent` is the LIVE tree the running gateway loads. Never
  `checkout`/`switch`/`rebase`/`commit`/edit there. All core work happens in a **separate local clone with its own
  gitdir** under `/tmp/hermes-wing-source`, on branch `feat/wing-session-source`, created from `origin/main`.
  - The card says "separate git worktree". Skill `hermes-core-fork-workflow` (section "NEUER GUARD") documents that
    a `git worktree` of the live repo is guard-blocked as well. It also documents that tests under
    `/mnt/HC_Volume_106183673/hermes/` trip `tests/home_io_guard.py`. A clone under `/tmp` is the documented
    equivalent.
- Core changes are **additive**: no behaviour change for any existing source (`desktop`, `tui`, `cli`, …).
- **Gateway restart and `hermes-up` are Birk's actions only, in a separate shell.** The plan stops and asks.
- Wing against a gateway without the advertisement must send exactly what it sends today: create with
  `source: 'desktop'`, resume without `source`.
- Wing test command: `bash tools/factory/ci-suite.sh`. It runs the **whole** pr-quality workflow (analyze + all
  Flutter tests + `scripts/tests`) on GitHub Actions for the **committed HEAD** and ignores path arguments.
  Commit first. Success = exit code 0 and a last line `ci-suite: run <id> conclusion=success …`.
- `flutter analyze --fatal-infos` must stay clean: no unused imports, prefer `const`.
- Core test command pattern (run from the clone, no `cd`):
  `env -C /tmp/hermes-wing-source TMPDIR=/tmp HERMES_PYTHON=/home/birk/.hermes/hermes-agent/venv/bin/python bash scripts/run_tests.sh <test paths>`
- Hint marker text (used by tests and the live check): `Standard Wing (Handy-App)`.
- No UI change: no new controls, labels or status text.
- Commit after every task. No push of Wing branches except the throwaway `ci/…` refs that `ci-suite.sh` creates
  and deletes. Push of the core feat goes to remote `fork` only (Task C3) and is not a deployment.
- `ANNAHME:` marks an unverified assumption together with the check that settles it.

## File map

| Repo | File | Status | Responsibility |
|---|---|---|---|
| core | `agent/session_source.py` | modify | `WING_SOURCE`, `DESKTOP_LIKE_SOURCES`, `UI_TRANSPORT_SOURCES` += wing |
| core | `gateway/session_context.py` | modify | `NON_MESSAGING_SESSION_SURFACES` += `"wing"` |
| core | `agent/tool_guardrails.py` | modify | `_ATTENDED_PLATFORMS` += wing |
| core | `agent/coding_context.py` | modify | `INTERACTIVE_CODING_PLATFORMS` += wing |
| core | `agent/conversation_loop.py` | modify | `_refresh_bot_chat_tools` gate |
| core | `agent/terminal_approval_batch.py` | modify | batch gate |
| core | `tui_gateway/session_lifecycle.py` | modify | `track_liveness`, `_desktop_automatic_cleanup` |
| core | `tui_gateway/session_reaper.py` | modify | `_ORPHAN_SWEEP_SOURCES` += wing |
| core | `hermes_state_maintenance.py` | modify | `sweep_orphaned_sessions` default `sources` += wing |
| core | `tui_gateway/session_workdir.py` | modify | `_LAUNCH_CWD_NOT_A_WORKSPACE`, `_resolve_create_cwd` gate |
| core | `tui_gateway/methods_session.py` | modify | `model_history_only` gate |
| core | `tui_gateway/contracts/events.py` | modify | `GatewayReadyPayload.session_sources` |
| core | `tui_gateway/ws.py`, `tui_gateway/entry.py` | modify | emit `session_sources` |
| core | `apps/shared/src/gateway-contract.generated.ts`, `apps/shared/src/gateway-contract.openrpc.json` | regenerate | contract artefacts |
| core | `tests/agent/test_platform_hint_wing.py` | create | acceptance: Wing prompt has the hint, desktop does not; both switch directions |
| core | `tests/tui_gateway/test_wing_session_source.py` | create | parity + advertisement |
| wing | `lib/core/services/wing_session_source.dart` | create | constants + `gatewayAdvertisesWingSource` |
| wing | `lib/core/services/profile_gateway.dart` | modify | `wingSourceAdvertised`, `sessionSource`, create/resume params |
| wing | `lib/core/services/profile_workspace_controller.dart` | modify | optimistic `ProfileChat.source` |
| wing | `test/wing_session_source_test.dart` | create | parser, gateway params, visibility |
| profile | `/home/birk/.hermes/profiles/birk/config.yaml` | modify | `platform_hints.wing.append` (Task D1) |
| profile | `/home/birk/.hermes/profiles/birk/skills/note-taking/voice-conversational-mode/SKILL.md` | modify | line 13 (Task D1) |

---

### Task C1: Core clone, acceptance test for the hint, and the alias set with parity

**Files:**
- Create: `/tmp/hermes-wing-source` (clone), branch `feat/wing-session-source`
- Create: `tests/agent/test_platform_hint_wing.py`
- Create: `tests/tui_gateway/test_wing_session_source.py`
- Modify:
  - `agent/session_source.py:16`
  - `gateway/session_context.py:185-188`
  - `agent/tool_guardrails.py:85`
  - `agent/coding_context.py:30`
  - `agent/conversation_loop.py:727-729`
  - `agent/terminal_approval_batch.py:293`
  - `tui_gateway/session_lifecycle.py:77`
  - `tui_gateway/session_lifecycle.py:363-364`
  - `tui_gateway/session_reaper.py:390`
  - `hermes_state_maintenance.py:156`
  - `tui_gateway/session_workdir.py:219`
  - `tui_gateway/session_workdir.py:247`
  - `tui_gateway/methods_session.py:968`

**Interfaces:**
- Produces, in `agent/session_source.py`:
  - `WING_SOURCE: str = "wing"`
  - `DESKTOP_LIKE_SOURCES: frozenset[str] = frozenset({"desktop", WING_SOURCE})`
  - `UI_TRANSPORT_SOURCES = frozenset({"tui"}) | DESKTOP_LIKE_SOURCES`
- Consumes: nothing.

- [ ] **Step 1: Create the clone and re-verify the citations**

```bash
git clone -q --local --no-hardlinks /home/birk/.hermes/hermes-agent /tmp/hermes-wing-source
git -C /tmp/hermes-wing-source remote set-url origin https://github.com/NousResearch/hermes-agent.git
git -C /tmp/hermes-wing-source remote add fork https://github.com/birkschmithuesen/hermes-agent.git
git -C /tmp/hermes-wing-source fetch -q origin main
git -C /tmp/hermes-wing-source switch -q -c feat/wing-session-source origin/main
git -C /tmp/hermes-wing-source grep -nE '== "desktop"|!= "desktop"|not in \("desktop", "tui"\)|_ORPHAN_SWEEP_SOURCES = |_LAUNCH_CWD_NOT_A_WORKSPACE = |_ATTENDED_PLATFORMS = |INTERACTIVE_CODING_PLATFORMS = |^UI_TRANSPORT_SOURCES|sources: tuple\[str, \.\.\.\] = \("tui", "desktop", "subagent"\)' -- agent tui_gateway gateway hermes_state_maintenance.py
```

Expected: the last command lists, among others, exactly these lines (numbers may differ by a few):

- `agent/coding_context.py:30`
- `agent/conversation_loop.py:728`
- `agent/session_source.py:16`
- `agent/terminal_approval_batch.py:293`
- `agent/tool_guardrails.py:85`
- `hermes_state_maintenance.py:156`
- `tui_gateway/methods_session.py:968`
- `tui_gateway/session_lifecycle.py:77`
- `tui_gateway/session_lifecycle.py:364`
- `tui_gateway/session_reaper.py:390`
- `tui_gateway/session_workdir.py:219`
- `tui_gateway/session_workdir.py:247`

Other hits belong to spec section 4 rows 14-18 and stay untouched:

- `agent/inline_tool_executors.py:223`
- `agent/initiate_setup_prompt.py:88/103`
- `tui_gateway/server.py:1985`
- `tools/…` (not in the grep scope)

If any of the 12 listed lines is gone, stop and re-run the spec section 4 audit on the new `origin/main`.

Then confirm the clone imports itself, not the live tree:

```bash
env -C /tmp/hermes-wing-source /home/birk/.hermes/hermes-agent/venv/bin/python -c "import agent.session_source as m; print(m.__file__)"
```

Expected: `/tmp/hermes-wing-source/agent/session_source.py`. ANNAHME: the editable install resolves to the cwd
first (skill `hermes-core-fork-workflow`, "Tests im Clone"). If it prints the live path, prefix the test commands
with `PYTHONPATH=/tmp/hermes-wing-source`.

- [ ] **Step 2: Write the acceptance test (the hint is in a Wing prompt and not in a desktop prompt)**

Create `/tmp/hermes-wing-source/tests/agent/test_platform_hint_wing.py`:

```python
"""Wing (phone client, source ``wing``) gets the conversation-mode hint from config; the desktop app does not.

Card t_9d9bcf31. The hint is pure config (``platform_hints.wing.append``); an unknown platform has an
empty built-in hint and still honours the override (agent/system_prompt.py _resolve_platform_hint). The
surface switch (agent/surface_switch.py) makes the mode follow the CLIENT when a session moves between
the Mac and the phone.
"""

from types import SimpleNamespace
from unittest.mock import patch

from agent.prompt_builder import PLATFORM_HINTS
from agent.surface_switch import stage_surface_switch_note
from agent.system_prompt import build_system_prompt_parts

WING_HINT = (
    "Standard Wing (Handy-App): Gesprächsmodus (Skill voice-conversational-mode, Abschnitt Ausgabekanal je "
    "Client). Wing liest deine Antwort selbst vor: Plain Text im Gesprächsstil, kein Markdown, keine Listen, "
    "keine Pfade, kein text_to_speech."
)
OVERRIDES = {"wing": {"append": WING_HINT}}


def _make_agent(platform: str) -> SimpleNamespace:
    return SimpleNamespace(
        load_soul_identity=False,
        skip_context_files=False,
        valid_tool_names=[],
        _task_completion_guidance=False,
        _tool_use_enforcement=False,
        _environment_probe=False,
        _kanban_worker_guidance="",
        _memory_store=None,
        _memory_manager=None,
        _platform_hint_overrides=OVERRIDES,
        model="",
        provider="",
        pass_session_id=False,
        session_id="",
        platform=platform,
    )


def _stable_prompt(agent) -> str:
    with (
        patch("agent.prompt_builder.load_soul_md", return_value=""),
        patch("agent.prompt_builder.build_environment_hints", return_value=""),
        patch("agent.prompt_builder.build_context_files_prompt", return_value=""),
    ):
        return build_system_prompt_parts(agent)["stable"]


def test_wing_prompt_has_the_conversation_hint_and_desktop_prompt_does_not(monkeypatch):
    monkeypatch.delenv("HERMES_DESKTOP_TERMINAL", raising=False)
    wing = _stable_prompt(_make_agent("wing"))
    desktop = _stable_prompt(_make_agent("desktop"))
    assert WING_HINT in wing
    assert PLATFORM_HINTS["desktop"] not in wing
    assert WING_HINT not in desktop
    assert PLATFORM_HINTS["desktop"] in desktop


def _switch(stored: str, current: str) -> tuple[bool, str]:
    agent = SimpleNamespace(
        provider="openrouter", api_mode="chat_completions", platform=current, session_id="s",
        _platform_hint_overrides=OVERRIDES, _surface_switch_note="",
    )
    prompt = f"SYSTEM PROMPT BODY\n\nModel: test-model\nProvider: openrouter\nPlatform: {stored}"
    staged = stage_surface_switch_note(agent, prompt, [{"role": "user", "content": "hi"}])
    return staged, agent._surface_switch_note


def test_mac_session_opened_in_wing_gets_the_wing_hint_as_turn_note():
    staged, note = _switch(stored="desktop", current="wing")
    assert staged
    assert WING_HINT in note


def test_wing_session_opened_on_the_mac_gets_the_desktop_hint_back():
    staged, note = _switch(stored="wing", current="desktop")
    assert staged
    assert WING_HINT not in note
    assert PLATFORM_HINTS["desktop"] in note
```

- [ ] **Step 3: Run it. Expected PASS already on unmodified core.**

```bash
env -C /tmp/hermes-wing-source TMPDIR=/tmp HERMES_PYTHON=/home/birk/.hermes/hermes-agent/venv/bin/python bash scripts/run_tests.sh tests/agent/test_platform_hint_wing.py
```

Expected: `3 passed`. This pins spec fact F3: the hint needs no core code. If it fails, stop. The premise that
the hint is pure config is refuted, and the spec must be revised.

- [ ] **Step 4: Write the failing parity test**

Create `/tmp/hermes-wing-source/tests/tui_gateway/test_wing_session_source.py`:

```python
"""Source ``wing`` (Wing phone client) behaves like ``desktop`` everywhere except the platform hint and the
desktop-only client tools (spec docs/superpowers/specs/2026-10-13-wing-client-source-design.md, section 4 in
the Wing repo; card t_9d9bcf31)."""

import inspect
import re
from pathlib import Path

import pytest

from tui_gateway import server  # noqa: F401  (binds the method_ctx modules below)
from tui_gateway import session_reaper, session_workdir

import hermes_state_maintenance
from agent import coding_context, tool_guardrails
from agent.session_source import ATTENDED_SOURCES, DESKTOP_LIKE_SOURCES, UI_TRANSPORT_SOURCES, WING_SOURCE
from gateway.session_context import NON_MESSAGING_SESSION_SURFACES

ROOT = Path(__file__).resolve().parents[2]


def test_vocabulary():
    assert WING_SOURCE == "wing"
    assert DESKTOP_LIKE_SOURCES == frozenset({"desktop", "wing"})


@pytest.mark.parametrize("source", ["desktop", "wing"])
def test_wing_shares_desktop_membership(source):
    assert source in UI_TRANSPORT_SOURCES
    assert source in ATTENDED_SOURCES
    assert source in tool_guardrails._ATTENDED_PLATFORMS
    assert source in coding_context.INTERACTIVE_CODING_PLATFORMS
    assert source in NON_MESSAGING_SESSION_SURFACES
    assert source in session_reaper._ORPHAN_SWEEP_SOURCES
    assert source in session_workdir._LAUNCH_CWD_NOT_A_WORKSPACE
    sweep_default = inspect.signature(
        hermes_state_maintenance.SessionMaintenanceMixin.sweep_orphaned_sessions).parameters["sources"].default
    assert source in sweep_default


def test_wing_launch_cwd_is_not_a_workspace():
    assert session_workdir._context_cwd_is_launch_artifact({"source": "wing"}) is True
    assert session_workdir._context_cwd_is_launch_artifact({"source": "telegram"}) is False


# Sites whose desktop check must accept wing (spec section 4, rows 1, 2, 6, 7, 9, 13). They read a live value,
# so a bare string comparison against "desktop" would silently exclude wing.
_PARITY_FILES = (
    "tui_gateway/session_lifecycle.py",
    "tui_gateway/session_workdir.py",
    "tui_gateway/methods_session.py",
    "agent/conversation_loop.py",
    "agent/terminal_approval_batch.py",
)
_BARE_DESKTOP = re.compile(r'[!=]= "desktop"|not in \("desktop", "tui"\)')


@pytest.mark.parametrize("rel", _PARITY_FILES)
def test_no_bare_desktop_comparison_left(rel):
    hits = [line for line in (ROOT / rel).read_text(encoding="utf-8").splitlines() if _BARE_DESKTOP.search(line)]
    assert hits == []


def test_desktop_only_surfaces_stay_desktop_only():
    # Wing cannot serve desktop_ui/catalog client tools (spec rows 14-16).
    assert 'platform == "desktop"' in (ROOT / "tui_gateway/server.py").read_text(encoding="utf-8")
```

- [ ] **Step 5: Run it to verify it fails**

```bash
env -C /tmp/hermes-wing-source TMPDIR=/tmp HERMES_PYTHON=/home/birk/.hermes/hermes-agent/venv/bin/python bash scripts/run_tests.sh tests/tui_gateway/test_wing_session_source.py
```

Expected: FAIL with `ImportError: cannot import name 'DESKTOP_LIKE_SOURCES' from 'agent.session_source'`.

- [ ] **Step 6: Implement the alias set and the parity edits**

The edits below are exact. Keep surrounding code unchanged.

`agent/session_source.py`: replace line 16, `UI_TRANSPORT_SOURCES = frozenset({"tui", "desktop"})`, with:

```python
# Wing (Android phone client) reports ``wing`` so the prompt can carry its own platform hint; everywhere else it
# is the desktop chat surface (same lifecycle, sweeps, guardrails). Only the hint and desktop-only client tools differ.
WING_SOURCE = "wing"
DESKTOP_LIKE_SOURCES = frozenset({"desktop", WING_SOURCE})
UI_TRANSPORT_SOURCES = frozenset({"tui"}) | DESKTOP_LIKE_SOURCES
```

`gateway/session_context.py:185-188`: add `"wing",` to the set (the module is the leaf `session_source` imports,
so use a literal):

```python
NON_MESSAGING_SESSION_SURFACES = frozenset({
    "", "api_server", "cli", "codex", "desktop", "gateway", "kanban", "local",
    "msgraph_webhook", "tool", "tui", "webhook", "wing",
})
```

`agent/tool_guardrails.py:85`:

```python
_ATTENDED_PLATFORMS = frozenset({"cli", "tui", "desktop", "wing", "acp", "subagent", "api_server"})
```

`agent/coding_context.py:30`:

```python
INTERACTIVE_CODING_PLATFORMS = {"cli", "tui", "acp", "desktop", "wing", ""}
```

`agent/conversation_loop.py:727-729`, in `_refresh_bot_chat_tools`:

```python
    platform = getattr(agent, "platform", None)
    from agent.session_source import UI_TRANSPORT_SOURCES
    if platform not in UI_TRANSPORT_SOURCES:
        return
```

`agent/terminal_approval_batch.py:293`:

```python
    from agent.session_source import DESKTOP_LIKE_SOURCES
    if (len(calls) < 2 or get_session_env("HERMES_SESSION_SOURCE") not in DESKTOP_LIKE_SOURCES
            or approval._gateway_notify_cb(approval.get_current_session_key()) is None):
```

The `from` line goes directly above the `if`, next to the other function-local imports.

`tui_gateway/session_lifecycle.py:77`:

```python
            track_liveness=str(surface or "").strip().lower() in DESKTOP_LIKE_SOURCES)
```

`tui_gateway/session_lifecycle.py:363-364`:

```python
    _desktop_automatic_cleanup = (
        end_reason in _AUTOMATIC_SESSION_END_REASONS and _session_source(session).strip().lower() in DESKTOP_LIKE_SOURCES)
```

Add at the module imports of `tui_gateway/session_lifecycle.py` (after `import contextlib`, line 10):

```python
from agent.session_source import DESKTOP_LIKE_SOURCES
```

`tui_gateway/session_reaper.py:390`:

```python
_ORPHAN_SWEEP_SOURCES = ("tui", "desktop", "wing", "subagent", "unknown")
```

`hermes_state_maintenance.py:156`:

```python
        self, *, max_idle_seconds: float, sources: tuple[str, ...] = ("tui", "desktop", "wing", "subagent"),
```

`tui_gateway/session_workdir.py:219`:

```python
_LAUNCH_CWD_NOT_A_WORKSPACE = set(DESKTOP_LIKE_SOURCES)
```

`tui_gateway/session_workdir.py:247`:

```python
    if raw_cwd and not explicit_cwd and source in DESKTOP_LIKE_SOURCES:
```

Add at the module imports of `tui_gateway/session_workdir.py` (after `from typing import Any`, line 9):

```python
from agent.session_source import DESKTOP_LIKE_SOURCES
```

`tui_gateway/methods_session.py:968`:

```python
        model_history_only=source in DESKTOP_LIKE_SOURCES and ctx.omit_messages)
```

Add `from agent.session_source import DESKTOP_LIKE_SOURCES` to the module-level imports of
`tui_gateway/methods_session.py`. Check first that the name is not already bound:
`git -C /tmp/hermes-wing-source grep -n "DESKTOP_LIKE_SOURCES\|^from agent" -- tui_gateway/methods_session.py`.

ANNAHME: importing `agent.session_source` at module level in the three tui_gateway modules creates no import
cycle. `agent/session_source.py` imports only `gateway.session_context`, which is stdlib-only (its docstring says
"A leaf"). Check: Step 7 passes. If it raises `ImportError` (circular), move the import into the function body,
the same way as in `conversation_loop.py`.

- [ ] **Step 7: Run both new tests plus the affected suites**

```bash
env -C /tmp/hermes-wing-source TMPDIR=/tmp HERMES_PYTHON=/home/birk/.hermes/hermes-agent/venv/bin/python bash scripts/run_tests.sh tests/tui_gateway/test_wing_session_source.py tests/agent/test_platform_hint_wing.py tests/agent/test_session_source.py tests/agent/test_tool_guardrails.py tests/agent/test_system_prompt_restore.py tests/agent/test_platform_hint_desktop.py tests/agent/test_terminal_approval_batch.py tests/agent/test_bot_chat_toolset_refresh.py tests/tui_gateway/test_session_platform_resolution.py tests/tui_gateway/test_startup_orphan_sweep.py tests/tui_gateway/test_gateway_owned_session_reap.py tests/tui_gateway/test_desktop_session_workspace_persistence.py tests/hermes_state/test_sweep_orphaned_sessions.py
```

Expected: all pass, and the runner's summary line reports 0 failed. If a file fails, run the same file on bare
`origin/main` (`git -C /tmp/hermes-wing-source stash`, re-run, `git -C /tmp/hermes-wing-source stash pop`) to
separate known upstream breakage (skill `hermes-core-fork-workflow`, "Vorschaeden") from a real regression.

- [ ] **Step 8: Commit in the clone**

```bash
git -C /tmp/hermes-wing-source add agent/session_source.py gateway/session_context.py agent/tool_guardrails.py agent/coding_context.py agent/conversation_loop.py agent/terminal_approval_batch.py tui_gateway/session_lifecycle.py tui_gateway/session_reaper.py hermes_state_maintenance.py tui_gateway/session_workdir.py tui_gateway/methods_session.py tests/agent/test_platform_hint_wing.py tests/tui_gateway/test_wing_session_source.py
git -C /tmp/hermes-wing-source -c user.name="Birk Schmithüsen" -c user.email=contact@birkschmithuesen.com commit -q -m "feat(session): wing source behaves like desktop except the platform hint" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

The git identity comes from skill `hermes-core-fork-workflow`, "Git-Identität".

---

### Task C2: Core advertises `session_sources` in `gateway.ready`

**Files:**
- Modify: `tui_gateway/contracts/events.py:51-57`
- Modify: `tui_gateway/ws.py:365-369`
- Modify: `tui_gateway/entry.py:310-314`
- Regenerate: `apps/shared/src/gateway-contract.generated.ts`, `apps/shared/src/gateway-contract.openrpc.json`
- Test: `tests/tui_gateway/test_wing_session_source.py` (append)

**Interfaces:**
- Consumes: `agent.session_source.WING_SOURCE` (C1).
- Produces (wire): `gateway.ready` payload field `session_sources: ["wing"]`. Wing task W1 parses exactly
  `frame["params"]["payload"]["session_sources"]` as a JSON list of strings.

- [ ] **Step 1: Append the failing test**

Append to `/tmp/hermes-wing-source/tests/tui_gateway/test_wing_session_source.py`:

```python
import asyncio
import json

from tui_gateway import ws as ws_mod
from tui_gateway.contracts.events import GatewayReadyPayload


def test_ws_ready_advertises_wing_source(monkeypatch):
    sent = []
    monkeypatch.setattr(server, "_WS_ORPHAN_REAP_GRACE_S", 0)

    class FakeWS:
        async def accept(self):
            pass

        async def send_text(self, line):
            sent.append(json.loads(line))

        async def receive_text(self):
            raise ws_mod._WebSocketDisconnect()

        async def close(self):
            pass

    asyncio.run(ws_mod.handle_ws(FakeWS()))
    ready = sent[0]["params"]
    assert ready["type"] == "gateway.ready"
    assert ready["payload"]["session_sources"] == ["wing"]


def test_ready_contract_declares_session_sources():
    assert "session_sources" in GatewayReadyPayload.model_fields
```

- [ ] **Step 2: Run it to verify it fails**

```bash
env -C /tmp/hermes-wing-source TMPDIR=/tmp HERMES_PYTHON=/home/birk/.hermes/hermes-agent/venv/bin/python bash scripts/run_tests.sh tests/tui_gateway/test_wing_session_source.py
```

Expected: 2 failures: `KeyError: 'session_sources'` and `AssertionError` on `model_fields`.

- [ ] **Step 3: Implement**

`tui_gateway/contracts/events.py`, class `GatewayReadyPayload` (line 51). Add after
`heartbeat: bool | None = None  # WebSocket transport only`:

```python
    #: Session ``source`` values this backend handles beyond the env default (``["wing"]``): a client sends
    #: its own source only when listed here, so an older backend never sees an unknown surface.
    session_sources: list[str] | None = None
```

`tui_gateway/ws.py:367-369`, the payload dict:

```python
            "params": {"type": "gateway.ready", "payload": {
                "skin": skin_payload, "change_events": True, "heartbeat": True, "replay_epoch": replay_epoch(),
                "session_sources": [WING_SOURCE],
            }},
```

Add at the module imports of `tui_gateway/ws.py`: `from agent.session_source import WING_SOURCE`.

`tui_gateway/entry.py:312-314`, the payload dict:

```python
        "params": {"type": "gateway.ready", "payload": {
            "skin": resolve_skin(), "change_events": True, "replay_epoch": replay_epoch(),
            "session_sources": [WING_SOURCE]}}},
```

Add at the module imports of `tui_gateway/entry.py`: `from agent.session_source import WING_SOURCE`.

Regenerate the contract artefacts:

```bash
env -C /tmp/hermes-wing-source /home/birk/.hermes/hermes-agent/venv/bin/python scripts/gen_gateway_contracts.py
```

Expected: `wrote apps/shared/src/gateway-contract.generated.ts` and
`wrote apps/shared/src/gateway-contract.openrpc.json`.

- [ ] **Step 4: Run the tests**

```bash
env -C /tmp/hermes-wing-source TMPDIR=/tmp HERMES_PYTHON=/home/birk/.hermes/hermes-agent/venv/bin/python bash scripts/run_tests.sh tests/tui_gateway/test_wing_session_source.py tests/tui_gateway/test_tui_gateway_ws.py tests/tui_gateway/contracts/test_generated.py tests/tui_gateway/test_protocol.py tests/tui_gateway/test_entry_picker_prewarm.py
```

Expected: all pass. Then:

```bash
env -C /tmp/hermes-wing-source /home/birk/.hermes/hermes-agent/venv/bin/python scripts/gen_gateway_contracts.py --check
```

Expected: exit 0 and no output.

- [ ] **Step 5: Commit in the clone**

```bash
git -C /tmp/hermes-wing-source add tui_gateway/contracts/events.py tui_gateway/ws.py tui_gateway/entry.py apps/shared/src/gateway-contract.generated.ts apps/shared/src/gateway-contract.openrpc.json tests/tui_gateway/test_wing_session_source.py
git -C /tmp/hermes-wing-source -c user.name="Birk Schmithüsen" -c user.email=contact@birkschmithuesen.com commit -q -m "feat(gateway): advertise session_sources in gateway.ready" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task C3: Hand the feat to the fork workflow (refs only; deployment is Birk's)

**Files:** none in Wing. `~/.hermes/hermes-agent-features.txt` (one line).

- [ ] **Step 1: Run the regression set for every file the feat touches**

```bash
env -C /tmp/hermes-wing-source TMPDIR=/tmp HERMES_PYTHON=/home/birk/.hermes/hermes-agent/venv/bin/python bash scripts/run_tests.sh tests/agent/ tests/tui_gateway/
```

Expected: no failure beyond those that also fail on bare `origin/main` (check each failing file there as in C1
Step 7). Record the pass/fail counts in the card comment.

- [ ] **Step 2: Mirror the feat ref into the live repo (ref only, no checkout)**

```bash
git -C /home/birk/.hermes/hermes-agent fetch /tmp/hermes-wing-source "+refs/heads/feat/wing-session-source:refs/heads/feat/wing-session-source"
git -C /home/birk/.hermes/hermes-agent log --oneline -2 feat/wing-session-source
```

Expected: the two commits from C1 and C2. Use the leading `+` and one branch, never a wildcard
(skill `hermes-core-fork-workflow`, "Ref-Spiegeln").

- [ ] **Step 3: Push to the fork**

```bash
git -C /tmp/hermes-wing-source push -q fork feat/wing-session-source
git ls-remote https://github.com/birkschmithuesen/hermes-agent.git refs/heads/feat/wing-session-source
```

Expected: the SHA equals `git -C /tmp/hermes-wing-source rev-parse feat/wing-session-source`.

- [ ] **Step 4: Register the feat**

Append the line `feat/wing-session-source` to the end of the active block in
`/home/birk/.hermes/hermes-agent-features.txt`, with a comment line above it:
`# wing source (Karte t_9d9bcf31): Wing meldet sich als "wing", Gesprächsmodus per platform_hints.wing`.
Check:

```bash
grep -n "feat/wing-session-source" /home/birk/.hermes/hermes-agent-features.txt
```

Expected: one non-comment line.

- [ ] **Step 5: STOP. Birk deploys.**

Report to Birk (card comment): "Core-feat `feat/wing-session-source` steht (2 Commits, Tests grün). Bitte in
separater Shell: `hermes-up`, danach Gateway- und Dashboard-Neustart." Do not run `hermes-up` or any restart
yourself. Task D1 Step 3 and Task W3 need this deployment. Tasks W1-W2 do not.

---

### Task W1: Wing parses the advertisement and sends its source

**Files:**
- Create: `lib/core/services/wing_session_source.dart`
- Modify:
  - `lib/core/services/profile_gateway.dart`: class `ProfileGateway` fields (after
    `bool reportsLiveChat = true;`, about line 145), `_forDashboard.open()` (about line 248),
    `createSession` (about lines 528-541), `resume` (about lines 543-551)
  - `lib/core/services/profile_workspace_controller.dart:2577`
- Test: `test/wing_session_source_test.dart`

**Interfaces:**
- Consumes (wire, from C2): `gateway.ready` frame
  `{"method":"event","params":{"type":"gateway.ready","payload":{…,"session_sources":["wing"]}}}`.
- Produces:
  - `const String wingSessionSource = 'wing';`
  - `const String desktopSessionSource = 'desktop';`
  - `bool gatewayAdvertisesWingSource(Map<String, dynamic> readyFrame)`
  - `ProfileGateway.wingSourceAdvertised` (`bool`, mutable, default `false`)
  - `ProfileGateway.sessionSource` (`String` getter)

- [ ] **Step 1: Write the failing test**

Create `test/wing_session_source_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/session_visibility.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'package:wing/core/services/wing_session_source.dart';

Map<String, dynamic> _ready(Map<String, dynamic> payload) => {
  'jsonrpc': '2.0',
  'method': 'event',
  'params': {'type': 'gateway.ready', 'payload': payload},
};

ProfileGateway _gateway(List<(String, Map<String, dynamic>)> calls) {
  final scope = WorkspaceScope(connectionId: 'host', profileName: 'a');
  return ProfileGateway(
    scope: scope,
    discover: () async => ProfileDiscovery(
      profiles: [HermesProfile(name: 'a')],
      currentName: 'a',
      activeName: 'a',
    ),
    get: (path, query) async => {},
    rpc: (method, params) async {
      calls.add((method, params));
      return {
        'session_id': 'runtime',
        'stored_session_id': 'stored',
        'info': {'profile_name': 'a'},
      };
    },
  );
}

void main() {
  group('gatewayAdvertisesWingSource', () {
    test('true only for a session_sources list containing wing', () {
      expect(
        gatewayAdvertisesWingSource(
          _ready({
            'session_sources': ['wing'],
          }),
        ),
        isTrue,
      );
      expect(gatewayAdvertisesWingSource(_ready({})), isFalse);
      expect(
        gatewayAdvertisesWingSource(_ready({'session_sources': 'wing'})),
        isFalse,
      );
      expect(
        gatewayAdvertisesWingSource(
          _ready({
            'session_sources': ['tui'],
          }),
        ),
        isFalse,
      );
      expect(gatewayAdvertisesWingSource({'method': 'event'}), isFalse);
    });
  });

  group('ProfileGateway source', () {
    test('stock gateway: create says desktop, resume sends no source', () async {
      final calls = <(String, Map<String, dynamic>)>[];
      final gateway = _gateway(calls);
      await gateway.createSession();
      await gateway.resume('stored');
      expect(calls[0].$1, 'session.create');
      expect(calls[0].$2['source'], desktopSessionSource);
      expect(calls[1].$1, 'session.resume');
      expect(calls[1].$2.containsKey('source'), isFalse);
      expect(gateway.sessionSource, desktopSessionSource);
    });

    test('advertising gateway: create and resume say wing', () async {
      final calls = <(String, Map<String, dynamic>)>[];
      final gateway = _gateway(calls)..wingSourceAdvertised = true;
      await gateway.createSession();
      await gateway.resume('stored');
      expect(calls[0].$2['source'], wingSessionSource);
      expect(calls[1].$2['source'], wingSessionSource);
      expect(gateway.sessionSource, wingSessionSource);
    });
  });

  test('wing sessions stay in the chat list', () {
    expect(SessionVisibility.chats.includes(wingSessionSource), isTrue);
    expect(SessionVisibility.chats.includes(desktopSessionSource), isTrue);
  });
}
```

- [ ] **Step 2: Commit the test alone and run the suite to see it fail**

```bash
git add test/wing_session_source_test.dart
git commit -m "test(gateway): wing session source negotiation" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- test/wing_session_source_test.dart
bash tools/factory/ci-suite.sh test/wing_session_source_test.dart
```

Expected: exit code ≠ 0, last line `ci-suite: run <id> conclusion=failure …`, with a failed step under `flutter
analyze` or `flutter test` (the URI `package:wing/core/services/wing_session_source.dart` does not exist).

- [ ] **Step 3: Implement**

Create `lib/core/services/wing_session_source.dart`:

```dart
/// Which session `source` Wing reports to the Hermes gateway.
///
/// Stock Hermes knows Wing only as `desktop`, the same as the Mac app. A
/// gateway that handles Wing's own source lists it in `gateway.ready`
/// (`payload.session_sources`); only then does Wing send `wing`, so an
/// unmodified gateway sees exactly the traffic it always saw.
library;

const String wingSessionSource = 'wing';
const String desktopSessionSource = 'desktop';

/// Whether this `gateway.ready` frame advertises the `wing` session source.
/// Any other shape fails closed to today's `desktop` behaviour.
bool gatewayAdvertisesWingSource(Map<String, dynamic> readyFrame) {
  final params = readyFrame['params'];
  if (params is! Map) return false;
  final payload = params['payload'];
  if (payload is! Map) return false;
  final sources = payload['session_sources'];
  return sources is List && sources.contains(wingSessionSource);
}
```

`lib/core/services/profile_gateway.dart`:

1. Add the import next to the other `import` lines of the file:

```dart
import 'wing_session_source.dart';
```

2. In class `ProfileGateway`, directly after `bool reportsLiveChat = true;`, add:

```dart
  /// Set from `gateway.ready` on every socket open (true and false, so a
  /// reconnect to an older gateway resets it).
  bool wingSourceAdvertised = false;

  /// The session `source` this gateway accepts from Wing.
  String get sessionSource =>
      wingSourceAdvertised ? wingSessionSource : desktopSessionSource;
```

3. In `_forDashboard`, inside `open()`, replace

```dart
        await candidate.connect();
        await candidate.waitForGatewayReady();
        if (closed) throw StateError('Gateway is closed');
        socket = candidate;
```

with

```dart
        await candidate.connect();
        final ready = await candidate.waitForGatewayReady();
        if (closed) throw StateError('Gateway is closed');
        gateway.wingSourceAdvertised = gatewayAdvertisesWingSource(ready);
        socket = candidate;
```

4. `createSession`: replace `'source': 'desktop',` with `'source': sessionSource,`.

5. `resume`: replace

```dart
      await call('session.resume', {
        'session_id': durableId,
        'omit_messages': true,
      }),
```

with

```dart
      await call('session.resume', {
        'session_id': durableId,
        'omit_messages': true,
        'source': ?(wingSourceAdvertised ? wingSessionSource : null),
      }),
```

`lib/core/services/profile_workspace_controller.dart:2577`: replace `source: 'desktop',` with
`source: resource.gateway.sessionSource,`.

- [ ] **Step 4: Run the suite**

```bash
git add lib/core/services/wing_session_source.dart lib/core/services/profile_gateway.dart lib/core/services/profile_workspace_controller.dart
git commit -m "feat(gateway): report source wing when the gateway advertises it" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- lib/core/services/wing_session_source.dart lib/core/services/profile_gateway.dart lib/core/services/profile_workspace_controller.dart
bash tools/factory/ci-suite.sh test/wing_session_source_test.dart
```

Expected: exit code 0, last line `ci-suite: run <id> conclusion=success …`. Existing tests that assert
`'source': 'desktop'` (`test/answer_branch_live_test.dart:40`, `test/profile_actions_live_test.dart:41`,
`test/profile_recents_visibility_test.dart:25`, `test/session_visibility_test.dart:23`) are fixtures for server
rows, not request params. They must stay green unchanged. If one fails, read it before changing anything.

---

### Task W2: Session list keeps showing all sessions (regression in the list test)

**Files:**
- Modify: `test/session_visibility_test.dart:15-33` (`FilterHost.rows`) and the test that asserts the visible chat
  titles

**Interfaces:**
- Consumes: `SessionVisibility` (unchanged).

- [ ] **Step 1: Add a wing row to the fixture and to the expected visible set**

In `FilterHost.rows` (`test/session_visibility_test.dart`), after
`{'id': 'chat', 'title': 'My conversation', 'source': 'desktop'},`, add:

```dart
    {'id': 'wing', 'title': 'Phone conversation', 'source': 'wing'},
```

Then find every assertion in this file that lists the visible titles or ids of `SessionVisibility.chats`:
`grep -n "My conversation\|'chat'" test/session_visibility_test.dart`. Add `'Phone conversation'` (or `'wing'`
for id lists) next to `'My conversation'` (or `'chat'`), in the same order as the rows.

ANNAHME: the expectations are explicit lists. If a test counts rows instead (for example `hasLength(n)`), raise
`n` by one for the `chats` and `all` cases and leave the `automated` counts unchanged. Check with the grep above
before editing.

- [ ] **Step 2: Run the suite**

```bash
git add test/session_visibility_test.dart
git commit -m "test(sessions): wing rows stay in the chat list" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- test/session_visibility_test.dart
bash tools/factory/ci-suite.sh test/session_visibility_test.dart
```

Expected: exit code 0, `conclusion=success`.

---

### Task D1: Profile config and skill text (Birk's profile repo)

**Files:**
- Modify: `/home/birk/.hermes/profiles/birk/config.yaml:1078-1080`
- Modify: `/home/birk/.hermes/profiles/birk/skills/note-taking/voice-conversational-mode/SKILL.md:13`

- [ ] **Step 1: Add the hint**

Replace the block at `config.yaml:1078-1080` (verify first with
`grep -n "platform_hints" -A 3 /home/birk/.hermes/profiles/birk/config.yaml`) with:

```yaml
platform_hints:
  telegram:
    append: "Standard Telegram: Gesprächsmodus mit Sprachnachrichten (Skill voice-conversational-mode)."
  wing:
    append: "Standard Wing (Handy-App): Gesprächsmodus (Skill voice-conversational-mode, Abschnitt Ausgabekanal je Client). Wing liest deine Antwort selbst vor: Plain Text im Gesprächsstil, kein Markdown, keine Listen, keine Pfade, kein text_to_speech."
```

Validate:

```bash
/home/birk/.hermes/hermes-agent/venv/bin/python -c "import yaml; c=yaml.safe_load(open('/home/birk/.hermes/profiles/birk/config.yaml')); print(sorted(c['platform_hints']), c['platform_hints']['wing']['append'][:25])"
```

Expected: `['telegram', 'wing'] Standard Wing (Handy-App)`.

- [ ] **Step 2: Update the skill sentence**

In `SKILL.md` line 13, replace the sentence that starts "Wing meldet sich beim Gateway als `desktop` …" and
runs to the end of the line with:

```
Wing meldet sich seit Karte t_9d9bcf31 als `wing` (nur wenn das Gateway `session_sources: ["wing"]` anbietet, Core-feat `feat/wing-session-source`); der Hinweis kommt über `platform_hints.wing`. Wechselt eine Session zwischen Mac und Handy, liefert der Core den Hinweis der aktuellen Oberfläche als Turn-Notiz nach. Fehlt der Hinweis in einer Wing-Antwort trotzdem (alter Gateway-Stand), aus dem Inhalt schließen und im Zweifel einmal fragen.
```

Commit both files in the profile repo, following its own commit rules (`docs/repo-strategie.md`), and only these
two paths.

- [ ] **Step 3: Effect after Birk's restart**

The config takes effect only after the gateway restart that Birk runs in C3 Step 5. Do not restart anything.

---

### Task W3: Live acceptance on the deployed gateway and the phone

Preconditions:
- Birk has run `hermes-up` and restarted gateway and dashboard (C3 Step 5).
- D1 is committed.
- The VAD chain merge (`t_145c5731`) and W1-W2 are merged into `voice-offline`. Merging belongs to the factory
  merge card, not to this plan.

**Files:** none (verification only). Record results as a card comment.

- [ ] **Step 1: The gateway advertises the source**

```bash
grep -n "session_sources" /home/birk/.hermes/hermes-agent/tui_gateway/ws.py
```

Expected: one hit inside the `gateway.ready` payload. This proves the deployed tree has the feat.

ANNAHME (spec section 11): the dashboard on `:9119` serves its WebSocket through `tui_gateway/ws.py`. Settled by
Step 4: a new Wing chat gets `source='wing'`.

- [ ] **Step 2: Build and install Wing on the phone (Birk approved tests and installs)**

1. Build the APK. CI `voice-apk.yml` builds the unsigned APK for `voice-offline` and pushes it to branch
   `voice-apk-bin`. Check that the build used the right commit:

   ```bash
   gh run list -R birkschmithuesen/Wing --workflow voice-apk.yml --branch voice-offline --limit 1 --json headSha,conclusion
   ```

   Expected: `headSha` equals `git rev-parse voice-offline` and `conclusion` is `success`. If not, dispatch it:
   `gh workflow run voice-apk.yml -R birkschmithuesen/Wing --ref voice-offline`.

2. Sign it:

   ```bash
   bash /home/birk/.hermes/profiles/birk/tools/technik/wing-voice-build.sh
   ```

   Expected: `source commit: <sha of voice-offline>` and a signed APK under `~/handy-builds/wing-voice/`.

3. Transfer and install in 2-MB parts. Follow skill `android-phone-remote-ops`,
   `references/voice-self-test.md` ("Phone on mobile data") and `references/xperia-vserver-adb-build.md`:
   1. `split -b 2000000` the signed APK.
   2. Serve the parts from the vServer Tailnet IP (`python3 -m http.server`, wrapped in `exec timeout 600`, own
      background call).
   3. On the phone, in one `hadb shell` per part: `curl -m 35 -o /data/local/tmp/wing.part.<n> …` plus
      `sha256sum`, compared with the local `sha256sum` of each part.
   4. `cat` the parts into `/data/local/tmp/wing.apk` and compare the full sha256.
   5. `pm install -r /data/local/tmp/wing.apk`, then `am force-stop com.tarkilhk.wing.voice`, then relaunch Wing.
   6. Clean up `/data/local/tmp/wing.*` afterwards.

   Check:

   ```bash
   hadb shell 'dumpsys package com.tarkilhk.wing.voice | grep -m2 -E "versionName|lastUpdateTime"'
   ```

   Expected: `lastUpdateTime` is today.

- [ ] **Step 3: Session list unchanged**

Before Step 4, note in Wing the 5 newest chats (titles). After Step 4, Wing's chat list shows the same 5 plus the
new chat. Cross-check that the server returns them:

```bash
python3 -c "import sqlite3; c=sqlite3.connect('file:/home/birk/.hermes/profiles/birk/state.db?mode=ro',uri=True); print(c.execute(\"SELECT id, source, title FROM sessions WHERE source NOT IN ('cron','tool','subagent','kanban','oneshot') AND archived=0 ORDER BY started_at DESC LIMIT 6\").fetchall())"
```

Expected: the new Wing chat (source `wing`) followed by the previously newest chats.

- [ ] **Step 4: New Wing session is recognisable in state.db and carries the hint**

In Wing, start a new chat and send "Kurzer Test: wie ist das Wetter?". On the Mac desktop app, Birk starts a new
chat and sends any short message. Then:

```bash
python3 -c "import sqlite3; c=sqlite3.connect('file:/home/birk/.hermes/profiles/birk/state.db?mode=ro',uri=True); [print(r) for r in c.execute(\"SELECT s.id, s.source, s.created_source, instr(COALESCE(sp.prompt, s.system_prompt, ''), 'Standard Wing (Handy-App)') > 0 AS has_hint FROM sessions s LEFT JOIN system_prompts sp ON sp.hash = s.system_prompt_hash WHERE s.source IN ('wing','desktop') ORDER BY s.started_at DESC LIMIT 4\")]"
```

Expected: the newest `wing` row has `('…', 'wing', 'wing', 1)`, and the newest `desktop` row (the Mac chat) has
`(…, 'desktop', 'desktop', 0)`.

The Wing reply should be plain spoken text without Markdown. Judge it by reading the reply in Wing; it is not an
automated check.

- [ ] **Step 5: Per-client switch (resume)**

In Wing, open an older Mac-created chat and send a message. Then:

```bash
python3 -c "import sqlite3; c=sqlite3.connect('file:/home/birk/.hermes/profiles/birk/state.db?mode=ro',uri=True); print(c.execute(\"SELECT session_id, instr(api_content, 'different interface: wing') > 0, instr(api_content, 'Standard Wing (Handy-App)') > 0 FROM messages WHERE role='user' AND api_content IS NOT NULL ORDER BY id DESC LIMIT 1\").fetchall())"
```

Expected: `[('<that session id>', 1, 1)]`.

ANNAHME: the `messages` table has columns `session_id`, `role` and `api_content`. Check:
`python3 -c "import sqlite3; c=sqlite3.connect('file:/home/birk/.hermes/profiles/birk/state.db?mode=ro',uri=True); print([r[1] for r in c.execute('PRAGMA table_info(messages)')])"`.
The column names were read from `agent/surface_switch.py:64-80` (`api_content`); the others are assumed.

- [ ] **Step 6: Batched approvals still work in Wing (spec ANNAHME, site 13)**

In a Wing chat, ask for two parallel terminal commands that need approval (for example: "Führe parallel
`touch /tmp/wing-a` und `touch /tmp/wing-b` aus"). Expected: Wing shows the approval sheet and both commands run
after approval. If no sheet appears, report it. Wing then needs `wing` removed from site 13 (Task C1,
`terminal_approval_batch.py`) as a follow-up.

## Follow-ups (not in this plan)

- Per-turn voice marker (option C): **gestrichen, Folgekarte**.
- The Mac desktop app sidebar shows `wing` rows as an unknown messaging platform
  (`apps/desktop/src/lib/session-source.ts:49`). Fixing it needs a desktop build. Folgekarte.
- Upstream PR of `feat/wing-session-source` to NousResearch: Birk's decision.
