# Manage Hermes from your phone

Wing keeps the controls you need close to the chats they support.

- **Bots** lists profiles across saved instances. Tap a name or message preview to open its continuing Bot Chat, or its avatar to edit appearance. The row menu offers live screen viewing and takeover, pin, hide and Bot settings. Bot settings opens the captured profile's existing editors. Hosted Discussion groups use 2–6 bots from one ready instance. [Bots guide](BOTS.md).
- **Hermes administration** opens on the selected profile. Manage models and reasoning, agent identity, skills, provider access, MCP connectors and scheduled tasks. Hermes runs scheduled tasks even when Wing is closed.
- **Hermes health** shows server diagnostics and profile checks for model access, tools, connectors and scheduled tasks. A check tells you what it observed; it does not send a model prompt or run a scheduled job.
- **Hermes analytics** defaults to **All**, summing activity, token usage and model breakdowns across profiles on the selected instance over 1, 7, 30, 90 or 365 days. Choose one profile in its header to narrow the view. OpenAI Codex subscriptions show an API-equivalent estimate using the same models.dev rates as the model picker; other providers retain Hermes's estimate. Unknown amounts remain unavailable.

The title-row warning triangle shows unresolved resource and profile issues. Tap it to inspect an issue and open Hermes health. Connection availability is shown by the connection LED and does not create health alerts. Configure device-local alerts at **Hermes health → Alert settings**, above Host. RAM and disk usage warnings start above 90% for two minutes and clear below 85% for two minutes; separate native-pressure toggles admit Hermes's critical reports immediately. Valid edits save automatically. Alerts collect while a workspace is open or Wing's existing background monitor is watching ongoing work. Doctor and security-audit findings stay in Health and do not create these alerts. [Alert settings and recovery](ADMINISTRATION.md#health-alerts).

Choose the right connection and profile before changing settings. Profile settings are shared with other clients using that Hermes profile; server-wide actions can affect every profile. Wing confirms actions with a wider scope and shows the result or an uncertain outcome.

[Explore Wing](FEATURES.md) · [Administration reference](ADMINISTRATION.md) · [MCP connector details](MCP_CONNECTORS.md)
