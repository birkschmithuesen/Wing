# Administration

Open **Hermes administration**, **Hermes health** or **Hermes analytics** from Wing's navigation drawer.

| Destination | Use it for |
| --- | --- |
| Hermes administration | Models, identity, skills, provider access, MCP connectors and scheduled tasks for the selected profile. |
| Hermes health | Host resources, server diagnostics and profile checks. |
| Hermes analytics | Activity, token usage and estimated costs. |

[Bot settings](BOTS.md#profile-options) opens these editors for the chosen bot. Changing settings there does not switch the selected chat's profile or model.

## Profile settings

Select the profile before opening an editor. Administration search takes you to the matching setting. Refresh updates the displayed configuration; it does not run diagnostics or test tools.

You can manage model defaults and supported reasoning options, identity and instructions, fallback models, memory settings, approval policy, compression, voice and scheduled tasks. Model defaults apply to new conversations; use the model selector inside a chat to change that conversation's model. [Profile voice](PROFILE_VOICE.md) explains speech synthesis settings.

**Models and reasoning → Subagent model** chooses the default route for new
subagents, or lets them inherit the parent model. Existing agents keep their
current route. **Behavior → Compression → Prepare compression ahead** can reduce
compression pauses, but preparing a summary can consume tokens even if it is
never used. Manual chat compression is described in [Slash commands](SLASH_COMMAND_SUPPORT.md).

Long-press a profile pill to choose its color. This device preference also colors the profile in Chats; it does not change settings on Hermes.

Settings and Identity show unsaved changes and offer Save and Close. If another client changed a field, compare **Current server value** with **Your value**, choose which to keep, then save. A failed or incomplete save keeps the form available for review. Refresh failures retain the last confirmed observation with its check time.

An explicit server refusal keeps the draft editable and shows its explanation,
including administrator restrictions when supplied. A timeout or failed readback
leaves the result uncertain; refresh and review before saving again. A conversation
model change can succeed while a separate Fast change is refused; Wing reports
both parts.

## Skills, tools and provider access

**Skills and tools** groups capabilities into Needs setup, Enabled capabilities and Not enabled. Enabling a capability may start setup on Hermes; enablement alone does not prove it is ready.

Installed skills offers instruction reading, recorded usage and available edit, archive or uninstall actions. Use the skill reader’s action menu to lock or unlock agent edits. A lock preserves
your existing manual editing rights and does not change the skill’s origin.
Bundled instructions are read-only. The instruction reader supports raw/formatted views, copying, sharing and Contents. Hold or drag its grip to browse sections and release to jump. Skill discovery, the library and agent plugins have separate destinations.

In Agent plugins, **Update installed plugins** checks and updates eligible installed
plugins in the selected profile. The receipt separates updated, current, failed,
review-required and skipped items. Held or pinned installs stay under Hermes'
policy; changes needing review remain for the operator. Refresh reads the current
inventory after an uncertain result. This action does not enable automatic updates.

Provider access belongs to the selected profile. Depending on the provider and credential source, Wing offers key management, sign-in, renewal, status checks and removal. Some external CLI logins must be completed on the server. Removing a saved sign-in does not revoke the provider account or necessarily clear credentials already in use.

Opening a key editor checks the selected profile's stored-key state. Switching
profiles from an untouched editor checks the newly selected profile before
showing its credential actions. The header Wing pulses during that check; a
failed check offers Retry.

Retained memory can be searched and read. Memory entry editing and deletion are unavailable. See [MCP connectors](MCP_CONNECTORS.md) for connector setup, sign-in and reconnection.

### Refreshing saved prompts

On the Hermes host, an operator can run
`hermes -p PROFILE sessions refresh-prompts --session SESSION_ID --json` to request
a saved conversation's system-prompt rebuild on its next turn. Omit `--session`
to request it profile-wide. The command retains conversation history and identity;
the next turn can incur a prompt-cache miss. Inspect the JSON receipt for the
resolved target. Stock Hermes has no remote API for this operation, so Wing has
no corresponding action. Refresh skills only reloads skill information and does
not perform this saved-prompt refresh.

## Scheduled tasks

Open **Profile → Scheduled tasks** to create, edit, pause, resume, run or delete routines. Search and the All, Active, Paused and Needs attention filters affect this list. Open a task for instructions, delivery, model, last-run details and recent runs.

When the last run has an error, use the copy icon to copy its full text. **Ask <profile>** takes you straight to a new chat in that task’s profile, outside any project. The header Wing pulses while the chat is created and the task name, recorded run time and error are sent. If creation fails, retry from that chat. It uses the same Ask action as Doctor findings.

Schedules include recurring intervals, daily/weekly/monthly choices, one-time dates or delays, and custom expressions. Server templates provide starting points. Set a schedule timezone or leave it empty to use the profile timezone; run timestamps display in phone time. Edit the late-run window and missed-run catch-up policy in the task editor. Editing a name or instructions preserves an unchanged schedule.

**Save on server** stores results on Hermes. Choose a discovered group chat to post results into a discussion; member mentions can ask bots to continue the work. Other delivery choices depend on the connected server's configured destinations and may need setup there. A model override applies to that task; Profile default is resolved when it runs.

**Run now** may take as long as the task itself. Leaving the screen does not cancel or repeat it. A paused task asks you to confirm **Resume and run**. Pausing a schedule does not stop a run already underway. If a response is lost, review the uncertainty notice before attempting another run or creating another task.

Recent runs starts with 20 records and can expand to the latest 100. Agent runs open their conversation; script runs show available output and errors. **Stop run** requests cancellation of the current execution without pausing its schedule, including while Run now is waiting. Wing does not offer script upload or a workflow builder. Hermes runs schedules even when Wing is closed. See [Scheduled tasks](SCHEDULED_TASKS.md) for timing, cancellation and group delivery.

## Health checks and diagnostics

Connection health includes whether the configured endpoint supports Wing chats.
A reachable standalone Dashboard produces **Chat address needs changing**; healthy
HTTP or provider checks do not clear that failure. Open the instance menu →
**Edit instance** and check the gateway Webapp address.

Health displays **Host**, **Server** and **Profile** separately. Each section has its own refresh and check time; there is no combined healthy verdict.

Host shows the connected machine's CPU, memory, disk, uptime and load when available. Tap the machine row for more details. Disk readings describe the Hermes data volume; process memory describes the API process, rather than all agents. Missing measurements stay unavailable.

Server contains Doctor, security audit and Logs. Its refresh runs both diagnostics. They also run on first entry and when a completed result is at least 24 hours old. Open a diagnostic for its output and rerun action. Leaving Health keeps an accepted diagnostic running. Results survive restarting Wing; an unfinished run is checked again without automatically starting another copy.

Doctor findings can offer **Ask Hermes**, which opens an editable draft containing the finding and available log. Review and send it yourself. Wing does not perform Doctor repairs. Logs supports source, severity and submitted text search, with up to 100 lines.

Profile checks cover model access, tool setup, connectors and scheduled tasks. Saved results are reused for up to 24 hours; refresh runs them again. These checks do not send a model prompt, execute tools or run jobs. A connector test can start its configured program. Resolved credentials do not prove available quota or successful model inference. **What's checked?** explains each result's limits.

MCP connector pages also show Hermes' cached runtime observation. Reading or
refreshing it does not run a connector test. Runtime recovery clears its own
runtime finding while preserving separate explicit probe results and timestamps.

Reported access problems offer the relevant recovery action, such as **Fix access**, **Review access**, **Retry** or **Review connection**. Routine model selection and account management remain in Administration. A failed refresh retains the previous result and time, qualified as last known.

## Health alerts

In **Hermes health**, tap the **Alert settings** sliders beside **Alerts**. Settings apply on this device across active connections. Memory and disk usage warnings start above 90% for two minutes and clear below 85% for two minutes. CPU warnings start disabled; their editable defaults are 95%, 80% and three minutes.

Warning and recovery durations can be set independently from 1 to 30 minutes. The clear percentage must be lower than the alert percentage. Valid edits save automatically; invalid text keeps the last valid rule. A failed save offers Retry.

Memory and disk also have separate **Native Hermes critical pressure alert** switches, enabled initially. These alerts can appear immediately even without a percentage reading. They are independent of the configurable usage warnings.

Wing watches while foregrounded or while its existing background task monitoring is active. Health alerts do not keep monitoring running by themselves. Paused or failed readings can leave an issue qualified as last known. Doctor and security audit findings do not generate these alerts.

Scheduled-task alerts clear when a successful task-list refresh confirms the error is resolved or the failed task has been removed, including after restarting Wing.

Wing also rechecks unresolved task alerts when it opens or resumes, including acknowledged issues for other profiles. A fresh healthy reading removes the issue without changing your selected profile.

Tap the toolbar warning triangle to open Quick view beneath it. Tap the issue or its open icon to reach its recovery screen. A connector alert opens the failed connector directly; if several failed, the connector list marks them. Profile alerts keep the connection and profile captured by the check. Resource alerts open Hermes health. Tapping a brief notice opens the same destination. Use the checkmark to acknowledge an issue and silence its cues for that occurrence, or the snooze icon to pause cues for 30 minutes. While saving, the dialog shows progress. Once saved, the choice removes the issue from the toolbar count. The undo and clock-arrow icons restore attention to an acknowledged or snoozed issue. A failed save keeps the issue active and lets you retry. The **Alerts** section lists every current issue with its status until recovery. If the list is empty, it shows **No current alerts**. Snooze expiry restores the warning. Escalation or recurrence alerts you again. These choices are saved on this device and survive app restarts and updates. Snooze retains its original deadline. Restored issues remain last known until fresh checks confirm their status. Dismissing a notice keeps the issue; recovery clears it. Health monitoring controls CPU, memory and disk alerts. Profile, connection and service alerts can still appear when it is off. Host continues to show measured pressure beside its meter. These are in-app alerts and do not require Android notification permission.

## Analytics

**All** is selected by default and sums usage across every profile on the current connection. Use the instance name in the header to change servers. The separate profile picker beside it offers All and every profile on that instance; choose a named profile to focus on its usage. This filter does not switch your chat workspace. Profile reads run concurrently, with up to ten requests in flight. If a profile cannot be read, the affected total stays unavailable or retains the previous complete observation, with a notice and Refresh to retry.

Analytics offers **1D, 7D, 30D, 90D and 365D** periods, a daily token grid and model/token breakdowns. Daily tooltips use compact token counts, such as 298M. Chart titles and Tokens/Cost controls change the displayed grouping. Recently viewed data is cached for five minutes across profile changes and screen visits. Older data stays visible while it refreshes in the background; the Updated time shows its age. Refresh requests fresh observations. Missing costs and partial coverage remain identified.

Token totals and model breakdowns can appear before the activity year finishes. Sections stay in place while loading. Scroll within the model breakdown for
additional models; the selected daily range includes days with no recorded usage.

OpenAI Codex subscription usage shows an **API-equivalent cost** using current direct OpenAI API base rates from models.dev. Other providers retain Hermes's estimate. Mixed history shows **Estimated usage value**. These values are estimates, not invoices or historical price reconstruction; cache-write charges, long-context premiums and service-tier adjustments are excluded. Missing prices leave the affected amount unavailable.

Daily records and model totals can cover different usage, and period edges may include partial days. Use the displayed coverage notes when comparing charts.

For connection details, versions and server updates, see [Connections and updates](CONNECTION_DIAGNOSTICS_AND_VERSIONS.md).
