# Queues, Recents, and pending input

## Follow-up queue

Queue adds text and attachments as a follow-up for the selected chat. Wing keeps
local unsent entries on the phone; once Hermes accepts a queued message, Hermes
owns when it runs. Accepted messages can run after Wing disconnects. The separate
composer draft remains available.

Tap a queued row for its supported Edit, Steer and Delete actions. Steer needs a
connected active turn and a text-only message. For a message with attachments,
the dimmed Steer action explains why it is unavailable. A local paused queue also
offers Resume.

Edit, or hold the row, to change the message in the composer. Saving a local
unsent entry keeps its position. Editing a still-queued message already accepted
by Hermes replaces it at the tail; steering transfers that exact accepted entry
into the current turn. Unavailable server controls stay disabled.

Cancel restores your separate draft; deletion requires confirmation. Back hides
the keyboard first, then cancels editing. Local submission pauses while an edit
is open; this does not pause work already accepted by Hermes.

Local entries need Wing to reconnect before submission. Restored work waits for
a server-state check. Stop, upload or send failure, and uncertain delivery pause
remaining local entries for review and explicit resume. Restarting does not
repeat uncertain work automatically. Failed saves preserve queued work and newer
composer edits. See [Drafts and outbox](DRAFTS_OUTBOX.md).

## Recents

Recents includes chats with messages from the last 24 hours and ongoing work
across profiles on the selected connection. Opening a chat, creating an empty
chat, or editing a draft does not make it recent. All, Running, and Needs input
stay at the top; the latter two filter by live state.

Back returns to Recents with your filter retained. Chats opened from Chats return
to Chats. Within a chat opened from Recents, swipe horizontally with two fingers
to switch to an adjacent conversation. Pinch inward to open the circular card
stack; accessible icon controls and keyboard controls are also available. Back
closes the stack first.

Recents also observes detached children and processes reported by Hermes, even
when the parent chat is idle or unopened. This indicates ongoing work; it does
not grant live control of that chat. Failed profile reads can leave coverage
incomplete. Open [Subagents](SUBAGENT_SUPERVISION.md) for a known parent's children.

## Sensitive input, approvals, and questions

Sudo passwords, environment secrets, vault unlocks, saved logins, and verification
codes use dedicated forms. Enter them there rather than in the composer. Typed
credentials stay in memory and are not saved in drafts or conversation messages;
after reconnecting, an outstanding form may return but its typed secret does not.
Withdrawn or expired requests close without being treated as a denial.

Approvals show the requested operation and the scopes Hermes offers, such as
Deny, Allow once, Session, and Always. Questions can contain multiple items and
retain confirmed answers. Requests belong to their original chat and profile.
Check the displayed outcome when a response cannot be confirmed.

## Side questions

`/btw`, `/bg`, and `/background` show the submitted question and any received
result. Empty results are labelled explicitly. These cards are temporary; a cold
restart may not recover the question or its linked result, and cancellation is
not available through these cards.

[Session controls](SESSION_CONTROLS.md) covers goals, loops, and processes.
[Notifications](BACKGROUND_NOTIFICATIONS.md) explains delivery and its limits.
