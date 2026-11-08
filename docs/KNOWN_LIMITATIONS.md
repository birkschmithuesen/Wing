# Good to know

Wing connects to the Hermes dashboard and Desktop Gateway. An API key alone is not enough.

- **Stay connected.** Wing keeps recent chats and drafts through brief outages and tries to reconnect. The Wing feathers pulse in the header during recovery while known Recents cards remain available; these cards reflect the last received data until fresh reads finish. Opening a saved chat during recovery continues after the chat list closes; Back cancels that opening. If needed, open the chat and tap **Retry**. Dashboard reads and downloads time out when the server stops responding. Some requests that change Hermes state can remain pending without a deadline.
- **Check uncertain delivery.** Wing retains a message whose delivery is uncertain and pauses its queue, including after reopening the app. Check the chat's server history, then edit or remove the uncertain message before resuming. Wing does not automatically resend it.
- **Get alerts.** Wing can notify you while you use other apps. Allow background battery use for screen-off alerts, and reopen Wing after restarting your phone. Very short work in chats you have not opened may not produce an alert.
- **Go offline.** You can read some recent chats without a connection; sending needs Hermes. A configuration backup saves connections and app settings. Conversations stay on your Hermes server.

- **Live voice history depends on Hermes.** Full GPT Live conversations are not
  yet saved to shared Hermes history or memory because the required supported
  recording operation is missing upstream. Spoken entries remain local until
  Wing restarts; delegated Hermes tasks and results are saved normally.
  [Explanation and upstream proposals](VOICE.md#why-the-full-spoken-conversation-is-not-saved).

[See what Wing can do](FEATURES.md)
