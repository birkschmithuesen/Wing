# Composer actions

When a chat is idle, the composer sends your message. While a turn is working and the composer is empty, its button shows **Stop**; tap it to interrupt that turn.

Typing or adding an attachment restores the arrow button. For a working chat, its default action is **Steer**. Choose Steer, Queue or Stop as your device default in App settings. Idle chats and slash commands use Send. When the preferred action cannot handle your draft, the arrow uses Send if it is available. Images and their captions enter the outbox together while Hermes is working, regardless of whether you paste or type first.

## Choose another action

Hold the arrow button, slide to a choice in the vertical selector, then release to act. The default is nearest the button. Slide outside to cancel. Choosing another action does not change your saved default.

Unavailable choices are dimmed and explain why they cannot run. A draft containing attachments cannot be steered. Queue waits for an in-flight send to finish before moving the draft. You can keep typing while it waits.

With an empty composer during a working turn, the button offers only Stop. Navigation, backgrounding and changed action availability dismiss an open selector without acting.

Screen readers provide named actions on the button. With a hardware keyboard, Tab reaches it; Enter or Space runs the available primary action. Down arrow, Menu or Shift+F10 opens its menu. Arrow keys select, Enter runs and Escape closes it.

## Steer and queue

Accepted steering appears as a compact steering row until Hermes adds it to saved conversation history. It then becomes a normal user bubble with formatted text and Copy. Saved steering also opens as a normal bubble when you return to a chat. Rejected steering or a connection failure keeps the draft. Text typed while a request is pending remains separate.

The queue appears above the composer as a compact count, whether connected or
offline. Expand it to see message previews and attachment names. Entries with
unknown outcomes, unconfirmed delivery or steering failures stay visible when
collapsed. Tap or hold an entry to open the same full-text detail sheet with
selection, exact Copy and supported actions. Temporarily unavailable actions
explain their restriction. Actions apply to the selected message and preserve
your separate draft. The queue disappears when empty. Connected queues send
after the current turn; a failed save restores the draft, and uncertain delivery
pauses the queue for review. See
[Queues and pending input](SUPERVISION_AND_QUEUES.md) and
[Drafts and outgoing messages](DRAFTS_OUTBOX.md).

Branch/Fork is an action on a saved answer, rather than a composer action. See [Conversation actions](CONVERSATION_ACTIONS_AND_READING.md).
