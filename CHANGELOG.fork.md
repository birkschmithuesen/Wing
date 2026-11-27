# Wing Voice — fork changelog

This file tracks what the fork `birkschmithuesen/Wing` (branch `voice-offline`,
app id `com.tarkilhk.wing.voice`) changes on top of upstream
[`tarkilhk/Wing`](https://github.com/tarkilhk/Wing). It does not replace
upstream's own `CHANGELOG.md`; that file stays upstream's.

Upstream base: commit `151ee281` (2026-09-28). Entries below cover every merge
commit between that base and `origin/voice-offline` to date, newest first.

See [AGENTS.md](AGENTS.md#fork-changelog) for the rule that keeps this file and
the README feature list current for every future change.

## 2026-11-27

### A closed chat's "Process updates unavailable" alert no longer outlives the chat
- **What:** the quiet, automatic `process.list` read in `_refreshProcesses`
  (`lib/core/services/profile_workspace_controller.dart`) reported an
  operational-error observation on every failure, with no corresponding
  clear once the chat it was reading stopped being the one the process
  watcher follows (`_syncProcessWatch`'s foreground target: `notificationChat
  ?? _current?.chat`, visible and live). A read that failed while its chat
  was foreground kept its `processes:<profile>:<sessionId>` incident forever
  once the user navigated away or the app backgrounded, since nothing ever
  issued a matching success/clear for a chat nobody has open anymore. The
  same quiet read also reported this alert for a server rejection meaning
  the runtime is detached/reaped (not in memory; the client should resume
  the stored session) exactly as it would a real failure, even though that
  rejection means the session is not live, not that it failed. Three fixes,
  all scoped to the quiet (`quiet: true`) read path only - an explicit
  refresh's reporting is unchanged: (1) the catch block in `_refreshProcesses`
  now only reports a real failure when the process watcher's current target
  is still this exact chat/runtime (`_processWatchTarget`) and the error's
  message does not contain `detached/reaped` (new `_isDetachedRuntimeError`,
  matching on `JsonRpcError.message` or `error.toString()`); otherwise it
  reports a clear (`error: null`) instead. (2) `_syncProcessWatch` now
  captures the chat it is about to stop watching whenever its computed
  target changes to a different chat (or to no chat), and clears that
  former chat's `processes:*` observation (new `_clearProcessObservation`)
  - this is what actually retires an already-raised alert the moment the
  chat is no longer open, independent of whether another read ever runs
  for it again. (3) `HealthAlertIncidentStore.read` now drops any persisted
  incident whose scope starts with `processes:` before restoring it, so a
  ghost alert saved under the old behavior does not survive the next app
  start (it was never going to receive another read to clear it either).
  The in-chat inline retry state (`chat.processesError`) is untouched by
  any of this; only the Hermes-health alert is scoped to "open and live".
- **Why:** card t_1f044762: Birk's health alert sheet kept showing stale
  "Process updates unavailable" entries (last known 3:08 PM / 8:06 PM /
  8:59 PM) for chats nobody had open anymore. The card's acceptance
  criteria: a failed quiet read for a not-live (detached/reaped) or
  not-open chat must not raise an alert; closing a chat or its runtime
  disappearing must clear its observation; pre-existing ghost observations
  must vanish on the next start; a real failure for a chat that IS open and
  live must still alert (checked by an independent reviewer).
- **Fork edits of upstream files:** `lib/core/services/profile_workspace_controller.dart`,
  `lib/core/services/health_alert_incident_store.dart`.
- **Tests:** `test/profile_background_work_test.dart` (new: "a
  detached/reaped quiet read never raises a user-visible alert", "closing
  the chat that holds a real quiet-read failure clears its alert").
  `test/health_alerts_test.dart` (new: "a persisted processes ghost
  incident does not survive the next read"). Real CI (run 46020128171, this
  sandbox has no Flutter SDK) failed only "closing the chat that holds a
  real quiet-read failure clears its alert", with no stack trace available.
  A from-scratch static re-trace of the exact event sequence (confirmed by
  an independent review pass and a line-by-line Python re-model of the
  `_syncProcessWatch`/`_refreshProcesses` state machine) found the
  implementation already satisfies this scenario; the one class of cause
  static reading cannot rule out is a `flutter_test` timing/dangling-Timer
  subtlety invisible without executing the suite. Hardened the test with
  explicit settle pumps around both state transitions and a trailing
  30-second pump confirming no read sneaks through once closed, matching
  this file's own established pattern in its passing sibling tests - no
  implementation change, since no concrete defect was found in it.
- **Merge:** pending · **Card:** t_1f044762

## 2026-11-25

### The combined chat list stops fanning a socket out to every profile too
- **What:** a device measurement (card t_241cf7b0, following up on
  t_6e3f8566/t_03f5043c, both merged in `3855b841`) found the socket fan-out
  survived through a third, independent caller of the same two readers:
  `ChatBrowserData._refresh` (`lib/core/services/chat_browser_data.dart`),
  which backs the combined Chats list ("every profile in one browser"),
  walks every profile `_controller.discovery.profiles` returns on every
  visit - cold start (the Chats screen mounts with no chat selected while
  `initialize()` is still in flight, and `ChatBrowserData` defers its own
  `refresh()` until the controller has both a discovery and a current
  profile, racing the selected profile's own connect) and every return from
  an open chat (`profile_workspace_screen.dart` nulls out its cached
  browser and rebuilds a fresh `ChatBrowserData` each time) - and called
  `browserCanonicalBotChat` and, unconditionally, `browserProjects` for
  each one. Both opened a brand-new throwaway `WsClient`, connected it, ran
  one RPC (`session.list`/`projects.tree`), then closed it - for every
  profile, including ones the user has never opened, every single visit.
  `browserCanonicalBotChat` gained the same `requireLive` flag
  `browserProjects` already had (added by t_6e3f8566): it throws unless
  that profile's own gateway is already live, instead of opening a reader.
  The worker in `chat_browser_data.dart` now passes `requireLive: true` to
  both, reusing a profile's own live socket when it has one. Canonical bot
  chat merge is purely cosmetic row styling, so a profile with neither a
  live socket nor an earlier successful read simply skips it, same as
  Recents' own profile-without-a-live-socket-keeps-stale-tags rule - a
  first widget-test pass that applied the exact same skip to project
  membership broke the combined browser's own cross-profile project
  list/filter/organize surface (`project picker follows profile filter`,
  `cross-profile project rename uses its captured production menu`, `Edit
  project feedback ... failure=folder/details` in
  `test/profile_workspace_browser_test.dart`/`test/chat_list_target_test.dart`
  - all show/edit a profile's projects without that profile ever being
  live, which the skip left permanently empty since nothing else ever
  populates that profile's project list). `browserProjects` itself now
  caches its result on `ProfileWorkspaceData` on every successful read,
  from any caller, and returns that cache instead of touching the network
  when the profile isn't live and the cache already has it - a pure
  optimization for Recents/`_readProjectMembership` that never changes
  what they already did on the exception they otherwise catch. A new
  `seedIfMissing` flag, set only by `chat_browser_data.dart`'s worker,
  additionally allows a one-time throwaway seed through a never-opened
  profile's first read (Recents and `_readProjectMembership` still throw
  instead, unchanged): every later read for that profile, including one
  from a brand-new `ChatBrowserData` instance after returning to the list,
  reuses the cache and never reopens a socket for it again. A second CI
  run (45646887042) caught that caching into `resource._projects` itself
  - the field `moveSessionToProject`/`selectProject` check continued
  project membership in by *identity* (`_projects.contains(project)`) -
  broke exactly that identity for any caller of `browserProjects`
  (`_readProjectMembership` runs on every chat open while membership is
  stale, which is most opens): a project `Map` captured earlier (e.g.
  "move to project X") stopped matching after the next chat open silently
  reassigned `_projects` to a freshly decoded list (`remove project
  retains assignment after move/default read failure and retries`,
  `remove project confirms and shows progress through every move stage`
  in `test/profile_row_actions_test.dart`). The seed/cache this card needs
  now lives in a new, separate `resource.browsedProjects`/
  `_browsedProjectsLoaded` pair nothing else reads, leaving
  `resource.projects`/`_projects` - and every identity check against it -
  exactly as untouched by this change as it always was.
- **Why:** card t_241cf7b0's acceptance criteria: the selected profile's
  socket must be ready <= 2s after `workspace.initialization_started` with
  nothing else (other profiles, Recents, health checks) running before or
  delaying it, at most 2 `ws.connect_started` in the first 30s, and no
  "Reconnecting" badge on a chat switch while the server is reachable and
  the selected profile's socket is live - find the fan-out source and the
  badge cause, not just the symptom. Robo's device measurement after
  t_6e3f8566/t_03f5043c confirmed the fan-out was not Recents or an opened
  chat's own membership read (explicitly ruled out by that measurement),
  which pointed at a second/third, still-unaudited caller; reading every
  caller of `browserProjects`/`browserCanonicalBotChat` found this one.
  The "Reconnecting" badge reappearing for ~20s on a second chat open is
  explained, not separately fixed or device-verified in this card: the
  throwaway connects this fan-out opened (several per visit, for profiles
  including the one the user was about to switch to) plausibly congested
  the selected profile's own resume right as the user opened the next chat,
  the same ticket-minting-congestion mechanism card t_341c53a1 already
  flagged for a different, still-open candidate
  (`bots_connection_source.dart`'s `savedBotsSession`, re-checked for this
  card and confirmed to loop over saved *connections* i.e. servers, not
  profiles - it only iterates once for a single-server device and is not
  this fan-out). Removing this fan-out removes the burst that caused it;
  whether the badge actually clears on-device is for the follow-up
  install/measure card, per this card's own instructions.
- **Fork edits of upstream files:** `lib/core/services/chat_browser_data.dart`,
  `lib/core/services/profile_workspace_controller.dart`.
- **Tests:** `test/chat_browser_data_test.dart` (new: "cold start never
  opens a throwaway socket for a profile other than the one it selects..."
  - starts `ChatBrowserData.start()` before `controller.initialize()`, the
  same race the real cold start has, and proves an unopened profile's
  project tree is seeded at most once even under that race; "returning to
  the chat list never re-opens a socket for a profile the user has not
  opened, once its project tree has been seeded..." - rebuilds
  `ChatBrowserData` three times, the same list-chat-list cycle production
  performs, and proves the seed from the first visit is reused, not
  repeated, by the second and third). Updated to the new contract:
  "canonical browsing reuses a live profile's own socket and never opens
  one for a profile the user has not opened, even while that profile's
  project tree seeds once..." (was: "...opens and retires readers without
  losing live chats" - the old contract expected a throwaway reader for
  every profile unconditionally; the new one asserts canonical merge opens
  none for an unopened profile, while still accepting exactly one
  project-tree seed, via the existing `_factory`/`ReaderFixture.opened`
  instance counter, not call counts) and "hidden Bot Chats obey visibility
  before and after opening and re-entry" (an unopened profile's hidden Bot
  Chat merge, specifically, no longer appears until that profile is
  actually opened - unlike its project tree, canonical bot chat merge has
  no cross-profile browse/filter/organize feature depending on it, so it
  stays purely skip-if-not-live). All four initially failed against the
  code with project membership *also* purely skip-if-not-live (same bug
  class as the one described in What, caught by this card's own CI run
  45636255207 after an initial push - see What for the fix that made them
  pass again) and pass against the final `seedIfMissing`-cached design.
- **Merge:** pending · **Card:** t_241cf7b0

## 2026-11-24

### Opening a chat no longer re-reads its own project membership through a throwaway socket either
- **What:** `_readProjectMembership` (`lib/core/services/profile_workspace_controller.dart`), called
  from `_loadChatProject` on every `_openSession` while a profile's project-membership cache is
  missing or stale, called `browserProjects(..., requireLive: false)` - the sibling of the Recents
  call site fixed below, left uncovered by that fix's `git grep` sweep because it is a different
  one of the three `_factory(` call sites in this file. `requireLive`'s default (`false`) still
  opens a brand-new `WsClient` via `_factory(scope)`, runs one `projects.tree` RPC, then closes it,
  even though the profile whose membership is being read is the one whose own chat the caller just
  opened - that profile's `resource.gateway` is already live at this point (opening its chat
  reached the success path that calls `_loadChatProject` in the first place). `_readProjectMembership`
  now passes `requireLive: true`, reusing that live socket; if the gateway is not live at read time
  (e.g. a reconnect raced in between the chat opening and this read), `browserProjects` throws and
  `_loadChatProject`'s existing catch turns that into "Project unavailable" instead of opening a
  throwaway socket.
- **Why:** review of t_6e3f8566 (card t_c095c26c) found the prior fix covered only one of the three
  `_factory(` call sites `git grep` turns up in this file; this is the second (the third,
  `browserCanonicalBotChat` at line ~2445, and `_resource`'s one-time gateway creation at line
  ~2646, are out of scope - neither is this defect). Cold-start socket-fan-out (review item 3) and
  the chat-switch "Reconnecting" badge (review item 4) are separate, independent-of-this-fix
  rebuilds that need their own analysis and tests; deliberately not addressed here, left to their
  own follow-up card(s).
- **Fork edits of upstream files:** `lib/core/services/profile_workspace_controller.dart`.
- **Merge:** pending · **Card:** t_03f5043c

### Recents stops opening its own throwaway gateway socket for every discovered profile on every refresh
- **What:** `_refreshRecents` (`lib/core/services/profile_workspace_controller.dart`) called
  `browserProjects(profile.name, ...)` for *every* profile `discover()` returned, on *every*
  refresh (chat list opening, pull refresh, and `WorkspaceRecentsSession`'s own 30s background
  poll while the list is visible) - with no caching at all on this path. `browserProjects` always
  opened a brand-new `WsClient` via a throwaway reader (`_factory(scope)`), ran one
  `projects.tree` RPC, then closed it - for every profile, including ones the user had never
  opened (a `default`/`checker`-style chip-only profile), and *in addition to* the selected
  profile's own real conversation socket, for the selected profile too. Because the throwaway
  reader's `WsClient` carries the same `{connection, profile}` diagnostic tag as the resource's
  own persistent gateway, its `ws.gateway_ready`/`ws.local_closed` lines were indistinguishable
  from the open chat's own socket in logcat - what looked like "the open chat's socket closes
  itself ~4-5s after becoming ready" was this second, throwaway socket for the same profile name,
  not the real one. `browserProjects` now takes a `requireLive` flag; Recents passes it `true`,
  which skips a profile entirely unless its own gateway is already live (reusing that socket for
  the read instead of opening another one) and otherwise keeps that profile's last-known project
  tags until the user actually opens it. The single-profile, user-initiated browse path
  (`chat_browser_data.dart`'s explicit profile browser) is unchanged - it already read lazily,
  one profile at a time, only when the user opened it.
- **Why:** card t_6e3f8566, following up on t_341c53a1/t_b0128763's cold-start restore scoping,
  which fixed the pending-turn/outbox restore sweeps but left this separate, undocumented fan-out
  path untouched. Device measurement on Birk's phone (build `692cad01`, 2026-11-24):
  `workspace.initialization_started` → `workspace.initialized` took 9.8s (target ≤2s) with 32
  `ws.connect_started` in the first 30s (target ≤2); the selected profile's own socket appeared
  to open 5.4s after tapping its chat and close again ~4-5s later while the chat stayed open;
  returning to the chat list reopened fresh `default`/`checker` sockets every time.
- **Fork edits of upstream files:** `lib/core/services/profile_workspace_controller.dart`.
- **Merge:** pending (branch `wing/t_6e3f8566-fix-wing-every-navigation-re-mints-socke`, not yet
  merged to `voice-offline`) · **Card:** t_6e3f8566

## 2026-11-23

### Cold start no longer fans a gateway socket out to every served profile's queued outbox right after the selected one initializes
- **What:** a device measurement (card t_341c53a1) found that, right after
  the selected profile (`birk`) logged `workspace.initialized`, the
  controller fanned out to every other discovered profile at once: the old
  `_finishInitialization` (`lib/core/services/profile_workspace_controller.dart`)
  unconditionally called `_restorePending()` (`Future.wait` over every scope
  with a durable unrestored-pending turn) and `_restoreWaitingOutboxes()`
  (a loop over every discovered profile with a queued draft), regardless of
  whether the user had ever opened that profile - 22 profiles on the
  measured device, ~31 sockets within 1.4 s. Each such profile's gateway
  then disconnected again shortly after (nothing was keeping it open), and
  because `ServerConnectionStatus.transportAvailability`
  (`lib/core/services/server_connection_status.dart`) is deliberately
  unscoped across every served profile on a connection (comment at its
  definition: it is the Health "Alerts" surface's input, not the header's),
  each of those disconnects could flip it to `unavailable` and make
  `health_alerts_session.dart`'s `_observeConnection` report "Connection
  interrupted" even though the selected profile stayed healthy throughout.
  Of the two sweeps, only the queued-outbox one could actually be made
  lazy: a queued outbox prompt is purely that profile's own composer state.
  `_restoreWaitingOutboxesFor(profileName)` replaces the global loop, but it
  is scoped to *both* a single profile *and* a single moment: it runs
  exactly once per connection, for whichever profile that connection's
  genuine first `switchProfile` (the one inside `_finishInitialization`'s
  one-time transition from not-initialized to initialized) selected - never
  from an ordinary later `switchProfile`/`navigateProfile` call. An earlier
  version of this fix ran it from every `switchProfile` call, scoped to
  whichever profile that call opened; CI (run 45218741379) caught that this
  broke `profile_workspace_controller_test.dart` "expired unsubmitted
  runtime keeps its draft and project on replacement" - a later
  `navigateProfile` during an in-flight expired-draft replacement raced
  this restore against `openSession(recoverExpiredDraft: true)`'s own
  migration of the same `ComposerDraftStore` entry, losing the queued
  prompt. A profile's queued outbox is therefore never auto-restored after
  cold start's own one-time pass; it isn't literally lazy-on-open for a
  profile opened later, but it also never again touches durable composer
  state behind an ordinary profile switch, which is what that regression
  needs to not happen.
  A first version of this fix also scoped the pending-turn sweep
  (`_restorePending`) the same way, to the opened profile only; CI (run
  45211216777) caught that this broke two other existing, intentional
  behaviours: `profile_live_activity_test.dart` "recovery resolves a title
  in a profile whose list is not loaded" and
  `profile_workspace_registry_test.dart` "process recreation restores only
  matching owners without resubmitting" both depend on a durable pending
  turn resuming for *every* served profile regardless of which one is
  selected, because Activity and notification recovery surface that turn
  across the whole connection, not only inside the profile that owns it.
  Pending-turn restoration is therefore still eager and global
  (`_restorePendingBatched`); what changed there is only the concurrency -
  the selected profile resumes first and alone, then the rest resume in
  batches of 3 (the same batch size `resumeConnection`'s background sweep
  already uses) instead of one unbounded `Future.wait` opening every
  profile's socket at once. A served profile that genuinely has no durable
  pending turn and no queued outbox - the common case for a profile the
  user has merely looked at before - is still never connected during cold
  start. `_recoverDeletedDrafts` was investigated too: it only ever does an
  HTTP discover + a plain dashboard REST read (`ProfileGateway.read`/
  `requireProfile`, both wired to `dashboard.apiGet`, not the WebSocket
  `connect()`/ticket path) and never opens a gateway socket, so it was left
  untouched - the serial `gateway.credentials_requested`/`ws.connect_started`
  walk the card also measured *before* `workspace.initialized` does not
  originate in `ProfileWorkspaceController.initialize()`. The strongest
  remaining candidate (not fixed here, see Why) is `savedBotsSession`
  (`lib/core/services/bots_connection_source.dart`): its per-saved-connection
  loop `await`s `controller.activateGroupNotifications()` - a real gateway
  ticket request and connect - one connection at a time, before the next
  connection's own request starts, and `BotsSession.refresh()`
  (`lib/core/services/bots_session.dart`) then reads every one of those
  connections' status/readiness/groups with one unbounded `Future.wait`.
- **Why:** card t_341c53a1's acceptance criteria: the selected profile
  initializes first and fast (`workspace.initialization_started` ->
  `workspace.initialized` <= 2 s), other profiles stay lazy or batched
  (<= 2 sockets in the first 30 s), and the "Connection interrupted" alert
  must not fire from the fan-out while the selected profile is connected -
  fix the cause, not the alert. A profile with genuine pending/notification
  work cannot be made fully lazy without breaking Activity and notification
  recovery across profiles (confirmed by the CI failures above, not by
  inference), so "at most 2 sockets in 30 s" is only reachable for the
  common case of profiles with no durable pending state; bounding the
  pending-turn sweep's own concurrency is the fix available without
  regressing that cross-profile behaviour. Verified the fan-out is real and
  scoped as described by reading every call site of `_restorePending`/
  `_restoreWaitingOutboxes` and the gateway's `connect()`/`_liveChanged`
  wiring (`lib/core/services/profile_gateway.dart`) rather than inferring
  it; separately verified `_recoverDeletedDrafts`'s `read`/`requireProfile`
  path is plain HTTP by reading `ProfileGateway._forDashboard`'s `get`/
  `discover` fields - a premise from the card brief (that this function
  caused the serial socket walk) that this reading refutes. Did not change
  `bots_connection_source.dart`/`bots_session.dart` in this pass: neither
  file has any existing test coverage, this sandbox has no local
  Flutter/Dart toolchain to compile or run against (`tools/factory/ci-suite.sh`
  needs a `git push` to a throwaway CI branch this run is not authorized to
  perform), and the causal link from that serial loop to the selected
  profile's own measured 13 s delay - plausible, given it issues a real
  gateway ticket request per saved connection with nothing prioritizing the
  selected one - was not confirmed against the device logs. Flagged as
  follow-up for a session that can verify it against the full suite.
  Explains, rather than fixes, the version-number flicker the card also
  asked about: `DrawerVersions`/`VersionsController`
  (`lib/core/widgets/drawer_versions.dart`) runs its own independent
  gateway (`ProfileGateway.forConnection`, profile `default`) purely to
  check the installed server version; it shares no object with the
  per-profile fan-out, but it shares the same dashboard server, so the same
  ticket-minting congestion that delays the selected profile's own ticket
  (Why, above) plausibly also delays/retries this gateway's own version
  check, flipping its label between `…` (loading) and the resolved version.
  Reducing the fan-out (What, above) reduces that congestion; it does not
  change `DrawerVersions` itself.
- **Fork edits of upstream files:**
  `lib/core/services/profile_workspace_controller.dart`.
- **Tests:** `test/profile_workspace_controller_test.dart` (new: "cold start
  restores only the initially selected profile's queued outbox; other
  profiles' queued outbox is never auto-restored" - proves a background
  profile with a queued outbox is never connected during cold start, and
  that switching to it later connects it without re-triggering the
  one-time outbox restore (a direct regression guard for the CI run
  45218741379 failure - see What); "a background profile's queued outbox
  refused during cold start does not flip the connection unavailable while
  the selected profile stays healthy" - proves a background profile's own
  connect failure, which the old eager outbox sweep would have reached, no
  longer reaches `ServerConnectionStatus.transportAvailability` once that
  profile's outbox is never connected in the first place). Both fail
  against the pre-fix code and pass against the fix. Left unchanged and
  re-confirmed passing against the fix: `profile_live_activity_test.dart`
  and `profile_workspace_registry_test.dart` (regressed by the first
  version of this fix, CI run 45211216777) and "expired unsubmitted
  runtime keeps its draft and project on replacement" (regressed by the
  second version, CI run 45218741379) - see What for both.
- **Merge:** pending · **Card:** t_341c53a1

## 2026-11-19

### The visible chat's own resume no longer scales with its saved transcript length or embedded image bytes
- **What:** a device measurement (card t_9fa64f90, follow-up to t_edbdd961)
  found `resumed` -> `visible_chat_resumed` still taking 7-10 s in a single
  retained chat, well over the <= 2 s target, even though t_edbdd961 already
  made the visible chat resume first. Root cause, confirmed in a throttled
  fake-transport test harness rather than by inspection alone: `resume()`
  (`lib/core/services/profile_gateway.dart`, `session.resume`) sent no
  `omit_messages`, so Hermes shipped this chat's whole display transcript
  over the socket on every resume - unbounded by the chat's own REST history
  page size - and `_resumeRetainedChat`
  (`lib/core/services/profile_workspace_controller.dart`) then awaited that
  REST page (`refreshHistory`), which can carry embedded image data URIs,
  before logging the step or letting the chat admit a new turn. Both legs
  scaled with this one chat's saved content instead of staying flat.
  `resume()` now defaults to `omit_messages: true` (every caller except
  `branch`, which reads the fork's content straight from this result,
  already re-fetches the transcript over REST via `refreshHistory`).
  `_resumeRetainedChat` gained a `deferHistory` parameter, used only for the
  profile's own visible chat: `chat._runtime.recovered()` (turn admission)
  now fires right after its now-tip-only `session.resume` lands, ahead of
  `refreshHistory`, which runs concurrently with the background chat sweep
  instead of being awaited inline. The streaming-placeholder clear and the
  recovered-turn notification (`_notifyRecoveredResult`, which reads
  `chat.reading.messages` - only populated once this transcript page has
  actually loaded) stay gated on that refresh *succeeding*, exactly as
  before CI caught the first version of this fix clearing an in-progress
  answer's placeholder, and sending a generic "Open the chat to see the
  outcome" notification, before the real content had loaded
  (`test/profile_workspace_controller_test.dart` "partial response survives
  resume until server history is available" / "reconnect notification uses
  recovered answer instead of generic status", CI run 44609585348).
  `_performReconnect` joins the deferred refresh after the background
  sweep, so a genuine (non-superseded) history failure still fails the
  whole reconnect attempt exactly as before, and images still load, just
  no longer gating the chat going live. Step names (`visible_chat_resumed`,
  `chats_resumed`, `sessions_refreshed`, `socket_connect`) are unchanged.
- **Why:** card t_0f45a26f. Checked `git log upstream/main --
  lib/core/services/profile_gateway.dart`: upstream's own `resume()` sent
  `omit_messages: true` (and no `display_projection`) before upstream's own
  canonical-session rewrite (`cdc5e070`, already merged into this fork's
  base) replaced it with `display_projection: true` and dropped
  `omit_messages` - an upstream regression, not a deliberate removal; the
  current Hermes contract (`tui_gateway/contracts/sessions.py`
  `SessionResumeParams`) still defines both fields independently, so
  sending both together is restoring prior, still-supported behavior, not
  inventing a new protocol; Hermes's own `_Resume.__init__`
  (`tui_gateway/methods_session.py:622`) comments "Desktop hydrates over
  REST; suppress the duplicate WS copy only when asked" - exactly the Wing
  usage this fix now makes. Upstream/main HEAD has not restored it either.
  Measured the actual payloads this bug ships with file:line citations:
  `profile_gateway.dart` `resume()` (~1288-1324, pre-fix) builds the
  `session.resume` request with no `omit_messages`, so Hermes's reply
  embeds every stored row of this chat (`SessionResumeParams.omit_messages`
  default `False`, `hermes-agent/tui_gateway/contracts/sessions.py`); the
  REST follow-up (`transcript_reading.dart` `refresh()`, ~981) fetches
  `historyPageSize` (50, `profile_gateway.dart` ~1466) rows with
  `inline_images: 'true'` by default - bounded in row count, but not in
  image bytes. The new test's throttled fixture reproduces a ~1.5-4 s
  transfer at 0.5 MB/s for a 5000-message chat with a handful of ~100 KB
  embedded images in its most recent page; on the old code both legs would
  have blocked `visible_chat_resumed`, failing the test well past its
  pumped window. Considered and declined `inline_images: false` with a
  lazy per-image reload: Hermes's `inline_images=False` only replaces an
  image part with the literal text `[image]` (`methods_session.py`); there
  is no reference left to re-fetch just that image, so "lazy load" would
  need a second full-page re-fetch with images - more surface than this fix
  needs once the REST page is off the critical path entirely. The
  double-transfer this card found (full transcript over the socket, then
  the same transcript again over REST) is itself inherent to Wing's current
  resume contract rather than something this fork's `omit_messages` fix
  fully closes for other callers; a draft upstream issue text (no
  instance-identifying detail) is in the card report for Birk to decide
  whether to file.
- **Fork edits of upstream files:** `lib/core/services/profile_gateway.dart`,
  `lib/core/services/profile_workspace_controller.dart`.
- **Tests:** `test/fork/visible_chat_resume_bandwidth_test.dart` (new:
  throttled-transport harness proves `visible_chat_resumed` and turn
  admission for the visible chat stay flat against a 5000-message
  transcript with embedded images, a case that blocks on the old code);
  `test/profile_workspace_controller_test.dart` and
  `test/slash_commands_test.dart` (updated: both assert the exact
  `session.resume` request map for an existing scenario, now including
  `omit_messages: true`). Not touched, and passing unmodified:
  `test/profile_workspace_controller_test.dart` "partial response survives
  resume until server history is available" and "reconnect notification
  uses recovered answer instead of generic status" - the two existing
  tests CI run 44609585348 caught regressed by the first version of this
  fix (see What above), confirming the corrected version defers the
  placeholder-clear/notification, not just turn admission;
  `test/profile_resume_freshness_test.dart` ("current history failure
  still fails profile recovery" / "superseded history failure cannot fail
  a recovered profile") - both keep passing unmodified too, since
  `_resumeRetainedChat`'s deferred path reuses the exact same
  superseded-read check before rethrowing, just joined later in
  `_performReconnect` instead of awaited inline.
- **Merge:** pending · **Card:** t_0f45a26f

### The selected profile's own visible chat resumes first, and the connection indicator clears, without waiting on its other retained chats
- **What:** t_15b221a3 (and t_1d748269 before it) made sure the *selected
  profile* resumes before and independently of any *background profile*,
  but a device measurement (`app.lifecycle resumed` -> `workspace.recovered
  profile=birk` = 57.9 s, acceptance of t_1d748269 not met) showed the
  remaining bottleneck was *inside* one profile's own reconnect:
  `_performReconnect` (`lib/core/services/profile_workspace_controller.dart`)
  resumed every eligible retained chat of that profile - any chat still busy
  from before backgrounding, plus the one on screen - serially, in one
  `for` loop, and only called `connectionStatus.endRecovery` (the call that
  clears `ServerConnectionStatus`'s `_recoveries` entry and lets `phase`
  leave `reconnecting`) after that whole loop plus
  `_restorePendingForResource`, `_journal` and `_refreshSessions` finished.
  The visible chat - the only one the user is looking at - could sit behind
  any number of other busy chats in map iteration order, and the header
  stayed on Reconnecting for as long as the slowest of them took, even
  though the socket itself (`ws.gateway_ready`, i.e.
  `ProfileGateway._liveChanged(true)`) was already healthy right after
  `gateway.connect()` resolved. Extracted the per-chat resume/refresh body
  into `_resumeRetainedChat` (unchanged logic, now returning an outcome:
  `resumed`/`skipped`/`aborted`) and reordered `_performReconnect`: the
  profile's own visible chat (`resource.chat`) resumes first and alone, and
  a new `visible_chat_resumed` step is always logged right there. Only when
  there are other retained chats left to process - the actual scaling
  problem this card is about - does `connectionStatus.endRecovery` also
  fire at that point, ahead of the rest; with no other retained chat (the
  common case, and every case a widget test held mid-recovery depends on:
  a chat deliberately left "opening", or a still-unresolved pending draft
  with nothing else retained), `endRecovery` stays exactly where it always
  was, at the very end, so nothing watching intermediate recovery state for
  that single chat sees any different timing. The remaining retained chats
  (when there are any) resume in a bounded-concurrency sweep (batches of 3,
  the same pacing already used by `resumeConnection`'s background-profile
  batching), followed by the unchanged pending-restoration, journal and
  session-list-refresh steps, all still awaited before the outer
  `reconnect()`/`_reconnect()` Future itself completes - so every other
  caller of `reconnect()` (notification approval, pull-to-refresh,
  waiting-outbox restoration) keeps seeing the same full-completion
  contract.
- **Why:** card t_edbdd961, the device-measurement follow-up to t_1d748269.
  Verified the three-hypothesis root cause in a test harness (fake host
  with several retained chats and a `session.resume` that never returns for
  background chats) rather than by inspection alone; the old loop provably
  never reaches the visible chat's own resume, let alone `endRecovery`,
  once an earlier chat in map order is stuck. Checked `git diff
  upstream/main -- lib/core/services/profile_workspace_controller.dart` and
  `server_connection_status.dart`: the serial per-chat loop and the
  `_recoveries`-gates-`phase` mechanism are both verbatim, unmodified
  upstream code (the fork's `focusOwner` scoping sits on top of the same
  gate) - this is an upstream bug, not fork drift. An upstream issue
  writeup (English, no instance-identifying detail) was drafted for Birk to
  decide whether to file.
- **Fork edits of upstream files:**
  `lib/core/services/profile_workspace_controller.dart`.
- **Tests:** `test/fork/visible_chat_resume_priority_test.dart` (new:
  proves the visible chat resumes and the header reaches `connected` while
  four other retained chats of the same profile are permanently stuck
  resuming - a scenario the old serial loop never gets past);
  `test/connection_diagnostics_test.dart` (updated: the per-step resume
  timeline test now also asserts `visible_chat_resumed` logs before
  `sessions_refreshed`); `test/profile_workspace_controller_test.dart`
  (added the `Host.resumeHold` per-call hook the new test needs to hold a
  specific chat's `session.resume` open indefinitely, unlike the existing
  single-use `resumeDelay`). Not touched:
  `test/profile_activity_status_test.dart` ("opening uses only the header
  pulse") and `test/profile_focus_recovery_test.dart` ("pending chat Retry
  shows recovery through history") both hold a *single* chat (or none)
  mid-recovery and check the indicator/pulse stays up throughout - exactly
  the no-other-retained-chat case this fix leaves at the original
  `endRecovery` timing, so both kept passing once the fast path was scoped
  to only fire when there is another retained chat to actually bound.
- **Merge:** pending · **Card:** t_edbdd961

### A foreground/network-restore resume no longer reconnects every served profile at all - only the selected profile and any profile with a turn still awaiting admission
- **What:** acceptance item 4 of t_a8358240 ("at most one gateway socket per
  instance, opened lazily; profiles multiplex over it, or only the selected
  profile connects eagerly and others connect on first real use") was still
  not met after t_b7f69683's batching: that fix only staggered
  `resumeConnection`'s per-profile reconnects in groups of 3, but still
  eventually opened one gateway socket for *every* resource matching
  `_needsLiveRecovery` - which answers true forever for any profile merely
  visited once (`resource._loaded`, set once by `switchProfile` and never
  cleared) or ever connected at all, even a failed attempt
  (`connectionStatus.hasLiveObservation`, cleared only on
  `gateway.close()`). `switchProfile`, `_selectChatProfile` (used by
  `openSession`/session switch) and `createChat` (new chat) each already
  call `gateway.connect()` for exactly one profile per event, so they were
  already compliant; `resumeConnection`'s background batch
  (`lib/core/services/profile_workspace_controller.dart`) was the one
  remaining fan-out. Added `_needsEagerResumeRecovery`, a narrower
  predicate that only answers true for a resource with an unrestored
  pending input, a turn still awaiting admission
  (`chat.runtime.blocksTurnAdmission`) or a queued follow-up prompt -
  genuine work the user is waiting on, not merely "ever touched this
  profile". `resumeConnection`'s background batch now filters on this
  predicate instead of `_needsLiveRecovery`; the selected profile keeps
  resuming first and unconditionally (unchanged from t_1d748269). An idle
  background profile - loaded earlier, or merely disconnected and sitting
  on its own backoff timer, but with no pending turn right now - is left
  alone; it opens its own socket lazily the next time the user actually
  switches to it or opens a session in it, which already calls
  `gateway.connect()` directly.
- **Why:** card t_15b221a3, following up on acceptance item 4 of
  t_a8358240 being refuted against the merged state as of 2026-11-19 (the
  per-event socket *count* was unchanged by t_b7f69683, only its pacing
  was). Checked `git log upstream/main --
  lib/core/services/profile_workspace_controller.dart`: upstream's own
  `resumeConnection` has no batching at all - a single unthrottled
  `Future.wait` over every `_needsLiveRecovery` resource - so the
  one-gateway-per-profile architecture and `_needsLiveRecovery`'s broad,
  permanently-true-once-touched definition are themselves unmodified
  upstream code (upstream's version is the same mechanism, just worse);
  this fix builds entirely on the fork's own t_b7f69683 batching, not on
  new upstream code. Also checked whether the gateway protocol itself
  would allow multiplexing several profiles over one socket instead:
  `DashboardClient.gatewayCredentials()` (`connection_manager.dart`) is
  connection-wide, not profile-scoped, but `WsClient.onStreamEvent`/
  `onConnectionChanged` (`ws_client.dart`) are single, non-multiplexed
  callbacks bound 1:1 to the one `ProfileGateway` each socket was opened
  for (`ProfileGatewayConnection.create`/`ProfileGateway._forDashboard` in
  `profile_gateway.dart`); sharing one socket across profiles would need a
  new event-demuxing layer fanning a shared socket's events back out to
  each profile's `ProfileGateway.onEvent`/`onConnectionChanged`, which is a
  materially larger and riskier change than this card's scope - used the
  brief's explicitly permitted fallback (selected profile eager, others
  lazy) instead.
- **Fork edits of upstream files:**
  `lib/core/services/profile_workspace_controller.dart`.
- **Tests:** `test/fork/resume_connection_burst_test.dart` (updated: the
  current-profile-first test now also asserts idle background profiles
  never connect at all, not just "not yet" by the time the current
  profile's own connect starts; the batching test is replaced by an
  assertion that an idle resume opens at most the selected profile's
  socket; added a new test proving a *background* profile with a turn
  still awaiting admission still resumes, alongside the selected profile,
  so "first real use" covers in-flight work and not only the profile on
  screen), `test/profile_workspace_controller_test.dart` (updated: 'retry
  clears a failed unopened profile while chat works' and the renamed
  'retry leaves an interrupted activity-only profile on its own backoff'
  - both exercised a chatless background profile that was merely
  `hasLiveObservation`/scheduled-for-backoff, which no longer gets an
  eager nudge from a resume event; it keeps ticking down on its own
  schedule instead).
- **Merge:** pending · **Card:** t_15b221a3

### The selected profile resumes first and alone on foreground return, and a background profile's own reconnect, failure or stale socket no longer keeps the header orange
- **What:** t_a8358240 (merged 091134b6) batched `resumeConnection`'s
  per-profile reconnects to stop opening every served profile's gateway
  socket at once, but batched strictly in `_resources` list order — so the
  selected profile could still sit behind one or two unrelated profiles in
  its batch of 3, and `ServerConnectionStatus.phase`/
  `recoveryAttemptInProgress` still aggregated every owner's `_recoveries`/
  `_failedRecoveries` unscoped, so the header stayed on Reconnecting (and
  the connection-details Retry button stayed disabled) until the *last*
  background profile's recovery settled, not just the selected one. Birk's
  2026-11-19 10:28 repro still showed ~18s to the selected profile's own
  `workspace.recovered` and ~26s to the last one. Fixed in three parts: (1)
  `resumeConnection` now resumes `_current` first and alone — awaited before
  the batched loop even starts — so its own recovery can never be seated
  behind other profiles; the rest still resume afterwards in the existing
  batches of 3. (2) `ProfileWorkspaceController._current`'s setter now calls
  the new `ServerConnectionStatus.focusOwner(profileName)`, which narrows
  `phase`, `recoveryAttemptInProgress` and `recoveryProblem` to the focused
  owner plus the three connection-wide pseudo-owners
  (`initialization`/`notification`/`notification-resume`) that must always
  gate the header. (3) `phase`'s connected/limited/disconnected branches
  also read the aggregate `live` map unscoped — so a background profile's
  socket actually going unavailable (not just mid-recovery) still turned the
  header from green to the `limited`/orange "Live updates interrupted"
  state even with (1) and (2) in place; added a focus-scoped `_focusedLive`
  for `phase`/`description` to read instead, while `live`/`access`/
  `transportAvailability` stay unscoped (the Hermes health Alerts surface
  still needs to see any background chat go unavailable, same split
  t_a8358240 already relied on). A 2026-11-19 operator follow-up noted a
  live repro with *no* `ws.connect_started` lines at all (sockets already
  open, `gateway.connect()` no-ops) that still took ~29s for the selected
  profile — added a `workspace.recovery_step` diagnostic log in
  `_performReconnect` with `elapsed_ms` after each awaited step (socket
  connect, per-chat resume, pending restore, journal, session refresh) so a
  future capture can localize that remaining delay; it does not change
  recovery behavior.
- **Why:** reported by Birk 2026-11-19 10:28 ("it still takes at least 10s
  until the server connection shows green and I can open a new session"),
  with a logcat repro the same morning at 10:30 pinpointing the delay to the
  selected profile's own recovery sitting behind others and the header
  staying orange for the whole batch. Diffing
  `lib/core/services/profile_workspace_controller.dart` and
  `lib/core/services/server_connection_status.dart` against `upstream/main`
  from the fork's merge-base (`7a9992c4`) shows zero changes to either file
  upstream — the one-gateway-per-profile architecture, `_performReconnect`'s
  sequential per-profile steps and `ServerConnectionStatus`'s cross-profile
  aggregation are the same unmodified upstream mechanisms t_a8358240's entry
  already identified; this card's fixes build entirely on the fork's own
  prior changes to those files, not on new upstream code. No upstream-issue
  draft file exists in this checkout to extend (the fork-factory `internal/`
  workflow referenced for that purpose does not apply here, see
  [AGENTS.md](AGENTS.md#fork-notes)); Birk can decide separately whether to
  fold this into or alongside t_a8358240's already-drafted issue.
- **Fork edits of upstream files:**
  `lib/core/services/profile_workspace_controller.dart`,
  `lib/core/services/server_connection_status.dart`.
- **Tests:** `test/fork/resume_connection_burst_test.dart` (new: the
  selected profile — reselected mid-list so it cannot win by coincidence of
  list order — must connect first and alone, before any background batch
  even starts), `test/server_connection_status_test.dart` (new: a background
  owner's own mid-recovery or failure must not reopen the header or block
  `recoveryAttemptInProgress` for a different focused owner, connection-wide
  pseudo-owners still gate regardless of focus, switching focus
  re-evaluates `phase` immediately, and a background owner's live socket
  actually going unavailable must not turn the focused owner's header
  orange), `test/connection_diagnostics_test.dart` (new: resuming the
  current profile emits a `workspace.recovery_step` timeline with
  `elapsed_ms` for every step up to `workspace.recovered`).
- **Merge:** pending · **Card:** t_1d748269

## 2026-11-18

### Session switch and new-chat both no longer force a retained chat through a visible reopen that blocks dictation, and a foreground/network-restore resume no longer opens every profile's gateway socket at once
- **What:** Two upstream-owned mechanisms combine to cause the reported 8–47s
  "Reconnecting" + disabled dictation on session switch (and, via the New
  chat button's `workspace.recovering` gate, on opening a new chat too).
  (1) `ProfileWorkspaceController.openSessionForReading` unconditionally
  called `beginOpening()` the instant a chat became visible, even on the
  retained/cache-hit fast path that requires its composer and history to
  already be fully restored (`_openSession`, the `retained.composer
  .observation.restored && retained.reading.historySessionId != null`
  branch) — so a chat the user can already see and type into stayed
  `runtime.opening == true`, and therefore `admitsDictation` kept dictation
  disabled, for the full duration of a redundant background
  `session.resume` + history refresh. `openSessionForReading` now only calls
  `beginOpening()` when the chat is not already ready (still opening or
  offline); an already-restored retained chat never re-enters opening, so
  dictation stays admitted across the switch. (2) `resumeConnection`
  (foreground entry / network-restore) fanned out `Future.wait` over every
  served profile's resource unthrottled; with several profiles loaded (the
  chat overview's per-profile filter chips), this opens one gateway socket
  per profile simultaneously, which Birk's server logs show saturating the
  single Hermes gateway process's event loop ("ws write slow, loop stalled
  >10.0s") — degrading whichever profile's socket the user is actually
  switching into or creating a chat in, so its own resume/reconnect (already
  sequential per chat, see `_performReconnect`) takes 8–47s instead of
  sub-second. `resumeConnection` now resumes profiles in small batches (3 at
  a time), the same idiom already used by `_refreshWorkspace`'s
  detached-work-roster polling, instead of all at once.
- **Why:** Birk reproduced 8–47s Reconnecting with dictation blocked on his
  phone 2026-11-18 ~19:08–19:10 CET; server logs for the same window show a
  burst of ~25 `ws accepted` within 200ms and a "loop stalled >10.0s"
  warning. A diff against `upstream/main` (7a9992c4) shows both mechanisms —
  `_resource()`'s one-gateway-per-profile architecture, `_performReconnect`'s
  sequential per-chat resume, `ServerConnectionStatus.phase`'s
  cross-profile `_recoveries` aggregation, and `openSessionForReading`'s
  `beginOpening`/`admitsDictation` gating — are unmodified upstream code;
  the fork's own diff in these files (unserved-profile refusal caching,
  the device-network gate, post-reconnect queue replay) runs after recovery
  ends or guards unrelated retry storms, and does not affect how long a
  reconnect takes. An upstream issue describing this (diff evidence, no
  device measurement since this sandbox has no `adb`/emulator and cannot
  push to trigger a CI build) is drafted for Birk to decide on filing.
- **Fork edits of upstream files:**
  `lib/core/services/profile_workspace_controller.dart`.
- **Tests:** `test/profile_resume_freshness_test.dart` (updated: a retained
  chat's instant reveal must not mark it opening, and must admit dictation,
  while its held resume RPC is still in flight — previously asserted the
  opposite), `test/profile_workspace_browser_test.dart` ('conversation keeps
  known project while reopening saved reading' asserted the same now-removed
  unconditional `beginOpening()` on a retained, already-restored chat;
  updated to check `refreshingConversation` for "the background refresh is
  in flight" and `runtime.opening == false` for "dictation stays admitted"
  instead), `test/fork/resume_connection_burst_test.dart` (new: a
  foreground/network-restore resume across 5 loaded profiles must not open
  more than the batch size's worth of gateway sockets at once, and must
  still resume every profile — the fixture simulates each profile's socket
  actually going stale first, via `onConnectionChanged(false)`, since a
  still-live socket is correctly left alone by `_resumeResource`'s
  `session.active_list` health-check fast path).
- **Merge:** pending · **Card:** t_a8358240

### A barge-in listen round and a chat-list working animation stop running once the app loses focus without a held background voice session
- **What:** `TurnListener` (the vad route's barge-in/listen-while-working round)
  restarted itself on silence forever once opened, never re-checking app focus
  again after the caller's one-time gate at `open()` - a round left listening with
  nobody speaking kept cycling native VAD/AudioRecord sessions (~every 8s, the
  listen round's `noSpeechTimeout`) for as long as the app stayed paused, whether
  or not car mode or a held background voice session was still running. It now
  takes an injected `canListen` callback, re-checked on every device event and
  before every round (re)start; `WorkspaceVoiceDriver` wires it to the same
  `loopFocus` the hands-free dictation loop already uses, so a round only opens or
  keeps running while in focus, in car mode, or while the explicit background
  voice service holds the microphone. Separately, `ChatWorkingBorder` (the chat
  list's pulsing border on a row Hermes is still working on) kept its
  `AnimationController.repeat()` ticking, and the raster thread compositing it,
  purely off `widget.working` and reduced-motion - lifecycle state never entered
  that decision, so the border (and any row showing "working" from a background
  conversation turn) kept animating with the screen off and nothing to show it to.
  It now also stops ticking once the app is not resumed. Both now call
  `WingBgWatch.instance.recordWakeup(...)` so a recurrence of either shows up in
  logcat; `GroupNotificationSession`'s background poll timer callback does too,
  closing a gap `WingBgWatch`'s own doc comment used to carve out for voice.
- **Why:** Measured 2026-11-18: Wing's native heap grew from 203 MB to 1.1 GB
  (VmRSS) over ~3.5 h paused with `voice.conversation=on`, `local_engine=parakeet`,
  screen off, and the raster and `WingVad`/`DartWorker` threads spinning
  (`1.raster 302`, `WingVad 91` ticks/12s) - new versus the prior, already-fixed
  main-isolate-only spin (t_5ba4ca8d, merged 64b968a5), where raster was idle.
  `dumpsys audio` showed Wing's `VOICE_RECOGNITION` sessions still starting and
  stopping 3.5 h after the app was last active, consistent with an unsupervised
  listen-round restart cycle rather than one Hermes conversation turn.
- **Fork edits of upstream files:** `lib/voice_offline/turn_listener.dart`,
  `lib/voice_offline/workspace_voice_driver.dart`,
  `lib/core/widgets/chat_working_border.dart`,
  `lib/core/services/group_notification_session.dart`,
  `lib/core/services/wing_bg_watch.dart`.
- **Merge:** pending (branch `wing/t_482d3051-wing-native-memory-grows-to-1.1-gb-and-c`,
  not yet merged to `voice-offline`) · **Card:** t_482d3051

## 2026-11-17

### Scheduled-tasks admin timers stop ticking on pause instead of only gating their callback, plus a background wake-up watchdog
- **What:** `ScheduledTasksObservation` and `ScheduledTaskDetailSession` (the admin
  Scheduled tasks list and a task's detail page) each create a single
  `Timer.periodic` in their constructor and never touch it again; `resumed(false)`
  only skipped the refresh *inside* the callback, so the Timer itself kept firing
  every 30s/8s and waking the main isolate for as long as either admin page stayed
  open in the background — a standing violation of "no component may wake the main
  isolate more than once per 60s while paused". Both classes now cancel and
  recreate their timer through a `resumed()`-driven `_reschedule()`, matching the
  `setVisible`/`setActive`/`setForeground` pattern already used by every other
  `Timer.periodic` in `lib/` (`BotGroupSession`, `BotScreenSession`, `BotsSession`,
  `SubagentSupervisionDetail`, `ChatNotificationApplication`,
  `WorkspaceRecentsSession`). Added `WingBgWatch`: a cheap, always-on counter that
  tracks timer/poll wake-ups per component while the app is not foreground and logs
  one `WingBgWatch component=count` line per minute when any component exceeds
  60/min, wired into the same `didChangeAppLifecycleState` in `main.dart` that
  drives every other foreground/background fan-out, and called from every
  background-eligible poll timer above (not from the three timers that only run
  during an active voice session or car mode, the agreed exceptions to the budget).
- **Why:** Investigating a reported 25-45% single-core CPU spin with the screen off
  and no rendering/network (`gfxinfo` frame count unchanged, Wing traffic ~0,
  `am force-stop` + relaunch returns CPU to 0 ticks/10s — a state the app drifts
  into, not one present from launch). The release build is unsymbolized, so an
  on-device profiler can only show `Looper.pollOnce`/epoll and unsymbolized AOT
  frames, not a component name. A static audit of every `Timer.periodic`,
  `Stream.periodic`, `AnimationController`/`Ticker` and
  `didChangeAppLifecycleState` in `lib/` found exactly one site where the Timer is
  never actually stopped on pause (the two classes above); every other timer
  already cancels through a visibility/foreground choke point. `WingBgWatch` exists
  because that audit is manual and release builds can't be profiled on-device: it
  is the cheap, always-on net for whatever regression the next change introduces.
- **Fork edits of upstream files:** `lib/core/services/scheduled_task_detail_session.dart`,
  `lib/main.dart`, `lib/core/services/bot_group_session.dart`,
  `lib/core/services/bot_screen_session.dart`, `lib/core/services/bots_session.dart`,
  `lib/core/services/chat_notification_application.dart`,
  `lib/core/services/chat_notification_coordinator.dart`,
  `lib/core/services/profile_supervision_session.dart`,
  `lib/core/services/workspace_recents_session.dart`.
- **New fork files:** `lib/core/services/wing_bg_watch.dart`.
- **Merge:** pending (branch `wing/t_5ba4ca8d-wing-main-isolate-spins-at-25-45-cpu-whi`,
  not yet merged to `voice-offline`) · **Card:** t_5ba4ca8d

## 2026-11-16

### A backgrounded active group discussion stops reconnecting/re-authenticating every 5 seconds
- **What:** `GroupNotificationSession` polled an active group discussion on the same fixed
  `pollInterval` (5s) whether the app was foreground or backgrounded. Each poll tick calls
  `read`/`command`, which call `gateway.connect()` directly; when the shared gateway socket is
  down, `connect()` performs a full `open()` (mints a fresh WebSocket ticket/OAuth bearer and
  re-reads `session.list`) with no backoff of its own, bypassing the exponential backoff
  `ProfileWorkspaceController._scheduleReconnect` already applies to its own reconnect path. A
  group discussion left active overnight (an unacknowledged send, or a still-"working" bot) kept
  this 5s cycle running the whole time the screen was off, repeating the full reconnect/re-auth
  handshake roughly twelve times a minute. Backgrounded polling now uses a separate
  `backgroundPollInterval` (default 60s) whenever the app is not foreground, keeping the
  foreground cadence unchanged.
- **Why:** Measured on Birk's Xperia 5 IV, 2026-11-16: Wing received 41/40/46/22 MB per 2h
  netstats bucket between 01:00-09:00 while backgrounded and not chatting (255 MB mobile + 76 MB
  Wi-Fi that day), batterystats blamed 284 mAh on Wing (second after tethering), and
  `BackgroundMonitoringService` was started 16x. A fixed-cadence background reconnect loop with no
  backoff, independent of whether the previous attempt had already failed, accounts for both the
  repeated bulk `session.list`/`groups.list`/`groups.state` transfers and (together with the
  `DashboardOAuthSession` fix below) most of the same night's token-refresh burst.
- **Fork edits of upstream files:** `lib/core/services/group_notification_session.dart`.
- **Merge:** pending (branch `wt/t_16567fa4`, not yet merged to `voice-offline`) · **Card:**
  t_16567fa4

### Hermes Cloud sign-in no longer rotates its refresh token in a tight loop against a buggy expiry
- **What:** `DashboardOAuthSession.bearerFor` refreshes the bearer whenever the current grant's
  `expiresAt` is not safely in the future; `_refresh()` had no protection against a server response
  that rotates in a replacement token whose own `expires_at` is already due for renewal (a clock
  skew or a bad expiry parse on the server), so every call needing a bearer re-triggered
  `POST /auth/native/refresh` immediately. `_refresh()` now tracks an exponential cooldown
  (2s, doubling to a 60s cap) that only advances when a rotation lands a token that is actually
  usable for a while; a renewal attempted before that cooldown elapses fails closed with
  `CloudAccessException` instead of rotating the single-use refresh token again.
- **Why:** The server's auth log recorded 5,698 `refresh_success` events from the phone on
  2026-11-16, all between 05:00-08:59 (peak 2,519 in hour 06, ≈40/min) versus 0 on prior days —
  consistent with a renewed token being judged already-expired on its very next use and refreshed
  again immediately, in a loop bounded only by how often something on the phone needed a bearer
  (see the `GroupNotificationSession` fix above for the dominant caller while backgrounded).
- **Fork edits of upstream files:** `lib/core/services/dashboard_oauth_session.dart`.
- **Merge:** pending (branch `wt/t_16567fa4`, not yet merged to `voice-offline`) · **Card:**
  t_16567fa4

### Wing no longer pushes a full chat notification for a NO_REPLY/silence-marker heartbeat reply
- **What:** `_settleTurn` now recognizes a final assistant reply whose entire text is a silence
  marker (`NO_REPLY`, `[SILENT]`, `SILENT`, `NO REPLY` and the CJK forms, trimmed of surrounding
  whitespace/punctuation, case-insensitive, new `isSilenceMarkerReply` in
  `answer_versions.dart`, hand-kept in sync with the Hermes
  `inbox_writer` plugin's `SILENT_MARKERS`/`_is_silence_marker`) and never builds
  `ChatNotificationContent.reply(...)` or calls `_deliverNotification` for it, regardless of the
  session's bot-mode title or whether the triggering message matches the `agent_message` envelope.
  `_notifyRecoveredResult`'s reconnect-recovery path excludes the same silence-marker-only text
  from counting as "the answer" so a missed-then-recovered silence reply does not alert either.
  Previously, suppression only applied to `bot_room` sessions or when the last user message
  matched the bot envelope regex (`_isBotExchangeReply`); a standby-heartbeat injection (not an
  `agent_message` envelope, not a `bot_room`/"Bot Chat" session) whose turn ended in a bare
  silence marker fell through both checks and pushed a normal OS notification.
- **Why:** Standby heartbeat probes intentionally reply with a silence marker when there is
  nothing to report; that convention already suppresses a note from the `inbox_writer` plugin
  server-side, but Wing's own notification gate did not know about it and alerted on every
  heartbeat tick regardless of bot-mode or envelope match.
- **Fork edits of upstream files:** `lib/core/models/answer_versions.dart`,
  `lib/core/services/profile_workspace_controller.dart`.
- **Merge:** merged (card t_86202f78 implementation + t_df1e9bf1 recovered-path
  test follow-up) · **Card:** t_f5b11c4a

## 2026-11-15

### Recents stops scanning a profile's entire session history on every refresh when a recent chat is pinned
- **What:** `_refreshRecents`'s per-page pagination loop only treats a session row as evidence of
  more unseen recent data the first time it sees that row's id. Hermes's `/sessions` endpoint
  re-appends every pinned row to each page it would otherwise be missing from (`include_pinned`
  back-fill), so a pin is never lost deep in history; a reappearing pin on a later page used to be
  treated identically to a genuinely new recent row, which keeps the "there might be more recent
  rows ahead" flag true forever and forces a full scan of the profile's entire session history on
  every refresh instead of stopping once a page holds nothing new. Confirmed against the real
  gateway: a pinned, recent chat reappeared on all but the first of 15 pages across a 1489-row
  account, turning a refresh that should read one page into fifteen.
- **Why:** Investigated as t_1cda51c3 (parent t_41381cc9): birk's newest desktop sessions
  (`__MASTER 2` / `20261114_141335_b2a261` and siblings from 2026-11-13..15) were reported missing
  from Wing's Recents/chat list although `SessionDB.list_sessions_rich`, `/api/sessions` and
  `tui_gateway.project_tree.build_tree` all returned them correctly on the server. An independent
  raw-JSON repro against the real gateway (read-only, same query shape Wing sends) confirmed the
  data is clean and already on the account's first page, and disproved the originally suspected
  `session_key = NULL` dedup collision: Wing keys and dedupes recents by session `id`, never by
  `session_key`, everywhere the visible chat list is built. This pagination defect is the one
  concretely confirmed, fixable client-side cause found during that investigation: a recent pinned
  chat (present on birk's account) makes every Recents refresh scan the full session history
  instead of the single page it should, directly matching the symptom of a stale, days-old list
  that never visibly updates. A further root-cause note (why the refresh never catches up on some
  accounts despite this fix) is tracked on the parent card.
- **Fork edits of upstream files:** `lib/core/services/profile_workspace_controller.dart`.
- **Merge:** pending (branch `wt/t_1cda51c3`, not yet merged to `voice-offline`) · **Card:**
  t_1cda51c3 (parent t_41381cc9)

## 2026-11-14

### The group-notification "default" profile and subagent.roster stop retrying a FINAL gateway refusal
- **What:** `isFinalGatewayRefusal` now treats any RPC code 4001 refusal that is not RETRYABLE as
  FINAL instead of matching a fixed reason allowlist, so a real-world 4001 with an unlisted reason
  (seen on `subagent.roster` for a served profile) is no longer retried forever on every
  `sessions.changed` event. Shared-discussion monitoring (`GroupNotificationSession`'s hardcoded
  "default" profile) now shares the connection's existing remembered-refusal cache
  (`isProfileServed`/`_markProfileUnserved`) in its `read`/`command` callbacks instead of calling
  `gateway.connect()` unconditionally on every poll, so a gateway that does not serve "default"
  stops reconnecting for it after the first refusal, even though `BotsSession`'s 10s background
  poll keeps calling `activateGroupNotifications()` every cycle.
- **Why:** After the connect/`session.list` and detached-work retry-storm fixes (t_8cdd1adb,
  t_0076f7aa, t_78c09092), a phone install still showed the unserved "default" profile
  reconnecting every 2-5s and `subagent.roster` tight-looping against the served profile, with the
  header stuck on "Reconnecting" as a symptom of the resulting repeated beginRecovery/failRecovery
  churn.
- **Fork files touched:** `lib/core/services/gateway_refusal.dart` (fork-only file, classifier
  broadened), `lib/core/services/profile_workspace_controller.dart` (upstream file, `read`/
  `command` callbacks guarded).
- **Merge:** pending (branch `wt/t_361e1de7`, not yet merged to `voice-offline`) · **Card:**
  t_361e1de7 (parent t_78c09092)

### Chats no longer offers a profile the gateway permanently refused
- **What:** A profile whose connect/`session.list`/`subagent.roster` answer is a FINAL gateway
  refusal (profile mismatch or unavailable) is remembered as not served for the life of the
  connection: Wing stops polling it for detached work and canonical-chat discovery (parent card),
  and the Chats profile picker row and the header's chat profile filter now show it disabled with
  a "not served by this gateway" hint instead of a tappable choice. A served profile is
  unaffected; the status clears only on an explicit refresh or a new gateway connection.
- **Why:** The parent card stopped a retry storm against a permanently-refusing profile on the
  backend only; this card closes its acceptance criterion 1 by surfacing the same status in the
  UI, so the user is not invited to keep retapping a profile Wing already knows the gateway will
  refuse.
- **Fork edits of upstream files:** `lib/core/widgets/profile_selector.dart`,
  `lib/core/widgets/chat_profile_bar.dart`, `lib/core/models/browser_actions.dart`,
  `lib/core/services/chat_browser_data.dart`, `lib/core/screens/profile_workspace_browser.dart`.
- **Merge:** pending (branch `wt/t_0076f7aa`, not yet merged to `voice-offline`) · **Card:**
  t_0076f7aa (parent t_8cdd1adb)

## 2026-11-12 (upstream merge)

### Upstream merge: tarkilhk/Wing e8a4089c (806 commits) into the fork
- **What:** Merged tarkilhk/Wing upstream/main e8a4089c (806 commits: gateway/chat rewrite, outbox, typed
  preferences, live voice call) into the fork. Fork voice, car mode and offline features re-hung on upstream's
  new seams (spec docs/superpowers/specs/2026-11-12-wing-upstream-merge-design.md).
- **Why:** Stay upstream-compatible (fork strategy).
- **User-visible:** Parakeet is chosen as "Recognition engine" under Local voice input (stored value migrated
  automatically); the settings card still hides "Recognition language" for the Parakeet engine; empty Parakeet
  recognition shows upstream's "No speech detected" notice; upstream's live call button appears (needs the Wing
  Hermes plugin) and a running conversation loop is paused while an upstream live call is active; the
  model-removal dialog uses icon buttons with tooltips (upstream dialog rules); unsent drafts/queues from before
  the update are not carried over (upstream format change, one-time step before install). Inline chat images now
  use upstream's image box (tap opens the preview).
- **Dropped for upstream:** own queue drain loop and history-text queue-head check (upstream outbox), composer
  toolbar mic (upstream mic in the text field).
- **Fork edits of upstream files/tools:** `lib/core/widgets/voice_preferences_card.dart`
  (VoiceOfflineEngineBuilder), `lib/core/services/profile_workspace_controller.dart` (NetworkGate +
  TransientSend mark/hold hooks), `tools/architecture` roles.json/roots.json registrations, and the car_mode
  cycle break (CarModeSession screenBuilder).
- **Final review fix:** the automatic queue resume spends its hold only for a `started`/`queued` replay receipt and
  marks the chat running only for `started` (a `terminal` receipt no longer leaves the chat running); the resume
  awaits an in-flight replay first.
- **Ledger L26 (Birk 2026-11-13):** Cancel on the recording screen discards only the current recording; in
  conversation mode the loop stays active and the microphone reopens for the next turn (upstream's chrome ended
  the loop). Regression test R9 (`test/regression/daily_flow_cancel_keeps_loop_test.dart`).
- **Upstream refresh:** merged upstream/main 7a9992c4 (15 commits after e8a4089c) in `79ed5cb1`; only conflict
  was the census list `tools/architecture/roots.json` (union).
- **Merge:** `116d82f4` · **Card:** t_d1d49ff1

## 2026-11-12

### Optional "ready" beep when conversation listening starts
- **What:** A new voice setting, "Signalton, wenn Zuhören beginnt" (default **on**, including for
  existing installs), plays a short beep when a conversation listen round opens the microphone for
  the user's turn after read-aloud has fully ended. It never plays for a round this listener
  restarts for itself while read-aloud is playing or might follow next: the barge-in round that
  stays open across playback (`keepPlayback`), or the round reopened right after an utterance was
  transcribed, before the reply exists. `TurnListener.open()` is the only call site eligible for
  the cue, and only when it is not opening for playback.
- **Why:** Birk, t_4f90f54c, 2026-11-12: wants an audible cue for exactly when the mic opens for his
  turn, without a beep every time the round silently restarts or barges into a reply.
  Reason: the default is ON per Birk's explicit instruction (card t_4f90f54c, 2026-11-12), a
  deliberate behaviour change for existing installs too, since this fork had no such cue before.
- **Merge:** [t_2c3aeb29] · **Card:** t_4f90f54c

### Internal: fork code moved out of upstream files (no behaviour change)
- **What:** Fork logic that lived inside upstream-owned files moved into fork-owned files
  (`lib/voice_offline/`, `lib/fork/`, `lib/car_mode/`, `voiceoffline/VoiceOfflineHandler.kt`,
  `android/app/voice-offline.gradle`, own test files); upstream files keep thin hooks. Lines in upstream
  files: +4351/-157 (38 files) -> +753/-175 (30 files); probe-merge conflicts against `upstream/main`
  e8a4089c: 27 files / 91 blocks -> 22 files / 94 blocks (blocks did not drop: the remaining hooks sit in
  heavily edited upstream code, and test-file hooks count too). Kept open: `profile_workspace_screen.dart`
  still +179/-55 (spec target about +60/-10).
- **Why:** Birk 2026-11-11: own code in own files keeps every later upstream merge small; the upstream
  merge card t_d1d49ff1 runs after this one.
- **Merge:** [t_3b4d8603] · **Card:** t_09ff7726 (parent t_ba3601fa)

### An unsolicited reply no longer breaks conversation mode or cuts the recording
- **What:** A reply that arrives while the conversation loop is not awaiting one (e.g. a background job's own
  turn finishing) no longer ends Conversation mode. While the user is recording or a barge-in listen round is
  open, the reply is queued instead of being spoken over the open mic or silently dropped; it plays once the
  mic closes and, if a regular reply is also queued, after that one. While idle it speaks normally and the
  loop still reopens the mic afterwards, exactly as after any other reply. A solicited reply (the loop's own
  turn) is unaffected.
- **Why:** Birk, t_0179b15f, 2026-11-12: `_speakCompletedReply` treated "no awaited reply" as reason enough to
  unconditionally null the conversation key, so any reply the loop had not itself requested tore the loop down
  — or, while the mic was open for it, got silently dropped instead of queued.
- **Merge:** `57ebb941` · **Card:** t_0179b15f (review t_3d97be71 APPROVED, merge t_ac33d45c)

## 2026-11-11

### BackgroundVoiceService now releases its wakelock when the conversation loop ends
- **What:** `BackgroundVoiceService` stops itself and releases its `PARTIAL_WAKE_LOCK` on every
  path that ends the background conversation loop (stop command from the notification, silence
  or a recognizer error ending the Dart hold, a phone call starting, the notification being
  dismissed, the hosting activity closing, a failed start) instead of only on some of them. A new
  10-minute safety idle timeout force-stops the hold if no `listening()` round activity happens
  for that long, so a hold can no longer dangle for hours even if some other end-of-loop signal
  never arrives. The "first reason wins" stop bookkeeping and the idle-timeout deadline math were
  pulled into plain `StopReason`/`HoldIdleTimer` Kotlin classes with JUnit tests (no Android
  framework dependency); the Service itself still needs instrumentation to verify, since
  `PowerManager`/`Service` lifecycle calls are not unit-testable without it, and this repo's CI
  (`pr-quality.yml`) only runs `flutter test`, not a Gradle/Kotlin test task.
- **Why:** Birk's phone, 2026-11-11: last `rec stop` 20:42:49, wakelock `$packageName:voice-conversation`
  acquired ~20:37 and still held at 23:26 (2h49m); `batterystats` since charge showed Wing as the
  top consumer (435 mAh) with `wakelock:fgs` held 3h05m and ~100 mAh/h screen-off drain. Fixed
  manually on the day by `am force-stop`; this card makes the service self-terminate instead.
- **Merge:** `852642d5` · **Card:** t_8f6a3d26 (review t_fbb61043 APPROVED, merge t_26c3971a)

### Read-aloud no longer speaks MEDIA reference lines
- **What:** Voice read-aloud (`spokenReplyText`) now strips `MEDIA:/path` reference lines — quoted and
  backticked variants included — before building the spoken text, reusing the same `mediaReferencePattern`
  the chat display already parses. The image/file card or thumbnail still renders; only the path is no
  longer read aloud. A sentence that merely mentions the word "media" is unaffected.
- **Why:** Wing's voice/conversation mode read the full reply text including `MEDIA:/home/.../file.png`
  lines verbatim, which is noise for a listener who only hears the card's presence, not its path.
- **Merge:** `1b7d5295` · **Card:** t_256dcf56

## 2026-11-08

### Car kit stays on the voice channel for the whole conversation
- **What:** A connected car hands-free kit (not a headphone) now keeps its Bluetooth voice channel (SCO) open
  for the entire conversation — dictation, listening-in (Mithören) and read-aloud barge-in (Reinreden) — instead
  of opening and closing it per round. Headphones keep the previous per-round behaviour unchanged. A round whose
  SCO link is not ready within ~1.5 s falls back to the phone mic for that round only.
- **Why:** Birk, in the car, 2026-10-19 ~18:00, after a successful test: the car kit's mic is audibly better
  than the phone's, but it dropped back to the phone mic for listening and read-aloud after every dictation
  round closed the link; keeping it open for the whole conversation is worth the trade-off that read-aloud then
  also plays in telephone quality instead of A2DP.
- **Merge:** pending (this card, t_7a553554) · **Card:** t_a19f7e1c (fix t_714bfc82, review t_ca18c5b2 APPROVED)
- **Docs:** [VAD_INPUT.md — Car-kit SCO hold](docs/VAD_INPUT.md#car-kit-sco-hold-conversation-wide-birk-decision-2026-10-19)

## 2026-10-30

### Chat images now show inline with a tap-to-zoom thumbnail
- **What:** An image deliverable (`MEDIA:` reference to a `.png`/`.jpg`/`.jpeg`/`.gif`/`.webp`/`.bmp` file)
  now renders as an inline thumbnail inside the chat message — full message width, aspect ratio kept, height
  capped at about 60% of the screen — instead of only a Download/Open-preview file card. Tapping the thumbnail
  opens the existing zoom preview. The Download/Open-preview row stays underneath the thumbnail. Bytes are
  fetched through the same authenticated remote-file path the card's own actions already use, and cached in
  memory by path so that scrolling the chat does not refetch an already-shown image. The file card is still
  shown while the image is loading or if the fetch fails, and several `MEDIA:` images in one message stack as
  separate thumbnails. SVG deliverables keep the file card unchanged — the app has no SVG renderer.
- **Why:** Birk 2026-10-30, Robo-reported MEDIA images render as a file card instead of an inline thumbnail in
  Wing conversational mode.
- **Merge:** pending (branch `wt/t_3dcd191e`, not yet merged to `voice-offline`) · **Card:** t_3dcd191e
- Superseded by upstream ChatInlineImage in the upstream merge (t_d1d49ff1).

## 2026-10-20

### Barge-in into read-aloud also opens for Bluetooth headphones
- **What:** Voice barge-in into read-aloud (`voice.barge_in_playback`) now also opens on Bluetooth
  headphones (`classifyRoute` reason `bluetoothHeadphones`), not only wired headphones. Speaker,
  car (without the car-mode override), `bluetoothOther` and `bluetoothClassUnknown` stay locked
  out.
- **Why:** Birk uses a Sony WH-1000XM4 over Bluetooth and found the barge-in gate stayed closed
  even though the route was already recognised as headphones; owner decision 2026-10-20 lifted
  the Bluetooth lock without waiting for an echo probe (t_fabcb273 closed as "not needed").
- **Commit:** `ff20a7b0` (pending merge) · **Card:** t_aad98b8c
- **Docs:** [VOICE_BARGE_IN.md — Barge-in during read-aloud](docs/VOICE_BARGE_IN.md#what-it-does)

## 2026-10-19

### Auto mode shows a "Listening — just talk" hint
- **What:** Auto mode (car mode) shows a "Listening — just talk" hint while recording.
- **Why:** Clarifies that the user can just start speaking once recording has started, without another tap.
- **Merge:** `f80f3cd4` · **Card:** t_9714a628

### Microphone source is manually selectable (Automatic/Phone/Bluetooth/Wired)
- **What:** Added a manual microphone-source setting (Automatic / Phone / Bluetooth / Wired) alongside the existing automatic headset-preferred rule.
- **Why:** The automatic rule did not fit every situation; some users want to force a specific input source.
- **Merge:** `d80f694d` · **Card:** t_7fa7d867

### Bluetooth headset microphone for vad rounds, headphone-detection fix
- **What:** Explicit on-device ("vad") recording rounds now use a connected Bluetooth headset's or car hands-free kit's microphone (HFP, recognised device classes) via `setCommunicationDevice` when one is present; also fixes a headphone-detection bug.
- **Why:** Lets the user dictate through a car's hands-free mic or a Bluetooth headset instead of only the phone's built-in mic.
- **Merge:** `1a3eda76` · **Card:** t_f4447207 (review t_be5e4ace APPROVED)
- **Docs:** [VAD_INPUT.md — Microphone route](docs/VAD_INPUT.md#microphone-route)

## 2026-10-17

### Auto mode starts without Conversation mode by default
- **What:** Auto mode (car mode) now always starts with Conversation mode off; a small switch turns it on explicitly.
- **Why:** Starting a continuous listening loop by default surprised users who only wanted single-shot talk-and-send.
- **Merge:** `5b5adae1` · **Card:** t_be848f7d

### Airplane mode no longer loses an offline message
- **What:** Fixed offline/airplane-mode handling so the connection status no longer gets stuck on "Connected", and a message recorded while offline is kept and sent once the connection returns instead of being lost.
- **Why:** A status that lies about connectivity, and a silently dropped message, both discard the user's spoken input.
- **Merge:** `cf72b3e8` · **Card:** t_dd058826

### Barge-in into read-aloud stops playback (part b, gated on echo measurement)
- **What:** Speaking while Wing reads a reply aloud now stops the read-aloud, behind the "Interrupt read-aloud by speaking" setting (off by default), restricted to wired headphones after a passing echo measurement (S2: `run50=0`, `p99<0.5`).
- **Why:** Lets the user talk over a reply they have heard enough of, without Wing's own voice triggering a false interruption.
- **Merge:** `477c639e` · **Card:** t_ac14c877
- **Docs:** [VOICE_BARGE_IN.md](docs/VOICE_BARGE_IN.md)

## 2026-10-16

### Headphone detection for barge-in into read-aloud (part b, groundwork)
- **What:** Added headphone-route detection (`classifyRoute` / `HeadphoneRouteChannel`) distinguishing wired, Bluetooth and speaker/car output.
- **Why:** Barge-in into read-aloud must trigger only with headphones, never through the open phone speaker (echo); detecting the route correctly is a prerequisite.
- **Merge:** `0d9cd8fb` · **Card:** t_c9c21f6d
- **Docs:** [VOICE_BARGE_IN.md — Headphone detection](docs/VOICE_BARGE_IN.md#headphone-detection)

## 2026-10-15

### Pause-until-sentence-end selectable up to 5 s
- **What:** Added 4 s and 5 s to the selectable "pause ends a message" durations.
- **Why:** Some users pause longer mid-sentence than the previously available choices allowed before Wing cut the recording.
- **Merge:** `e00ee3c9` · **Card:** t_1ef89dd4

### Conversation mode with the screen off
- **What:** On the on-device ("vad") input route, Conversation mode can keep running with the screen off or the phone pocketed, backed by a microphone foreground service and a "Conversation mode" notification with Stop.
- **Why:** Lets the user keep talking to Wing hands-free without having to keep the screen on.
- **Merge:** `cfc6a825` · **Card:** t_7200d190
- **Docs:** [VOICE.md](docs/VOICE.md)

### Read-aloud queue: a new reply waits its turn
- **What:** A new assistant reply arriving while a previous one is still being read aloud is now queued and read after the current one finishes, instead of interrupting it.
- **Why:** Avoids cutting off read-aloud mid-sentence just because a new reply started streaming.
- **Merge:** `28c67aa6` · **Card:** t_98343b76

### TTS detects German/English per sentence
- **What:** Read-aloud now detects German vs. English per sentence (offline function-word counting) and switches the Android TTS voice/language per segment, with a short pause between paragraphs.
- **Why:** Wing's replies mix German and English sentences; reading everything in one fixed language misreads the other.
- **Merge:** `f38b00a7` · **Card:** t_de1636ce
- **Docs:** [VOICE_LANGUAGE.md](docs/VOICE_LANGUAGE.md)

### Barge-in part (a): listening while Hermes works
- **What:** On the on-device ("vad") input route, with Conversation mode and "Listen while Hermes works" on, the microphone stays open for the whole turn; a `TurnListener` runs continuous VAD listen rounds and a `BargeInCoordinator` steers each utterance into the running turn, queues it, or sends it as a new prompt.
- **Why:** Lets the user keep talking to or steering a running reply instead of waiting for it to finish before saying anything else.
- **Merge:** `fff2ed93` · **Card:** t_658ec55c (review t_a3f1f1d6 APPROVED)
- **Docs:** [VOICE_BARGE_IN.md](docs/VOICE_BARGE_IN.md)

## 2026-10-14

### Wing client source and Conversation mode default
- **What:** Set the app's own client source identifier and the default state of Conversation mode.
- **Why:** Groundwork needed before building the barge-in / listen-while-working features on top of Conversation mode.
- **Merge:** `161ea958` · **Card:** t_94f1f373 (branch t_1c5bc62e, review t_e6118441 APPROVED)

### Internal merge: fold in-progress car-mode docs before the feature merge
- **What:** Internal integration merge resolving a conflict in the voice-background design/plan docs between two in-progress branches ahead of the car-mode merge.
- **Why:** Kept the car-mode branch's design docs consistent before the feature landed on `voice-offline`.
- **Merge:** `8b408656` · **Card:** t_f0c1d125 / t_6382a14f (internal to the car-mode chain, no standalone card)

### Auto mode: full-screen talk button (car mode)
- **What:** Added car mode: opening a chat's "Car mode" turns the whole screen into one big talk button, with state-dependent tap behaviour (start/stop recording, steer a running reply, queue while offline) and large connection/activity indicators.
- **Why:** A single, large, reachable button is safer to operate while driving than the normal composer.
- **Merge:** `beba7c9e` · **Card:** t_b22000e9 (review t_654826fe APPROVED)
- **Docs:** [CAR_MODE.md](docs/CAR_MODE.md)

### Internal merge: bring the vad input route onto the car-mode branch
- **What:** Internal integration merge folding the on-device "vad" voice input route (merge `b4f5e4a0`, card t_145c5731) into the car-mode development branch before that branch's own merge into `voice-offline`.
- **Why:** Car mode needed the vad route available on its branch before it could build the full-screen talk button on top of it.
- **Merge:** `c9d9811b` · **Card:** t_145c5731 / t_c0789ae5 (internal to the car-mode chain, no standalone card)

### Bring in the on-device "vad" voice input route
- **What:** Merged in the on-device "vad" voice input route: own audio capture with Silero VAD end-of-utterance detection, media-key fallback, Bluetooth-mic source selection, listening/got-it cues, and on-device debug WAV recordings.
- **Why:** Enables fully offline speech input instead of depending on Android's or Hermes' online recognizers.
- **Merge:** `b4f5e4a0` · **Card:** t_145c5731
- **Docs:** [VAD_INPUT.md](docs/VAD_INPUT.md), [VOICE.md](docs/VOICE.md)

## 2026-10-13

### Raise the dictation cap from 120 s to 600 s
- **What:** Raised the maximum dictation/recording length from 120 seconds to 600 seconds (10 minutes).
- **Why:** 120 seconds was too short for longer dictations (brainstorming dictations run 3-6 minutes).
- **Merge:** `6fc2691f` · **Card:** t_d259c976 (implementation t_d3a672fe)

### Scale the stop() transcription deadline with recording duration
- **What:** `VoiceCapture`'s deadline after `stopListening()` now scales with recording length (`5 s + 0.5 × duration`, capped at 90 s) instead of a fixed 5000 ms timeout.
- **Why:** The fixed timeout cut off long on-device transcriptions (a ~53 s session was cut off exactly 5.054 s after capture end).
- **Merge:** `7bf6c354` · **Card:** t_99f481cb
