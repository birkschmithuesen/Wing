# Drafts and outgoing messages

Each conversation has one editable draft and an ordered outbox of unsent messages.

Selected `@` identities stay with their draft or outgoing-message edit. Files
are read at dispatch, and unavailable selections pause the entire message.
See [server references](FILES.md#reference-a-file-on-the-hermes-server).

The reference-enabled build uses a new local draft format. Earlier v2 draft and
outbox records are not migrated; finish or export unsent work before upgrading.

Typing or adding attachments creates a draft. Clearing both removes it. Send saves the current text and attachments into the outbox before contacting Hermes, then clears the composer so you can start another draft. Sending waits for an attachment still being prepared; a failed initial save keeps the editable work and prevents submission.

The outbox is visible above the composer whenever it contains messages, both
online and offline. Send and Queue add to the same list, including images and
captions waiting for an active turn to finish. Local submissions remain visible
until Hermes acknowledges them or you delete them. Accepted queued messages then
use Hermes' reported queue state. Tap an entry for queue actions or hold it to edit. An empty outbox is hidden.

Offline Send keeps the message on this device. After reconnecting and checking the conversation, messages known to be waiting are sent in order when the chat is idle. Acknowledgement retires the local submission; it does not clear newer composer text or other outgoing messages. A message accepted into Hermes' queue remains visible as server-owned queued work until it runs or is cancelled. Hermes can drain that accepted queue after Wing disconnects. Acceptance does not mean the answer is finished.

## Uncertain delivery

If acknowledgement is lost or Wing closes during submission, the item stays paused for review. Wing never automatically resends it. Check the server conversation, then edit or remove the uncertain item before continuing. Matching text in history, or its absence, cannot conclusively establish whether Hermes accepted a lost-response send.

A deleted server conversation keeps its unsent work paused without blocking other conversations. Recovering a draft to another conversation may leave two recoverable copies if interrupted; review them before sending.

## Saved-message actions

Edit and Restore preserve your separate draft and pause outgoing follow-ups for review. Regenerate and Branch use the chosen saved answer. See [Conversation actions](CONVERSATION_ACTIONS_AND_READING.md) and [Queues and pending input](SUPERVISION_AND_QUEUES.md).

Drafts and local unsent outbox records are device-local and are not included in configuration backups. Hermes owns messages already accepted into its queue. A failed device-storage write cannot guarantee that the latest edit was saved.
