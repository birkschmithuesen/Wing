# Conversations and saved-answer actions

## Drafts and sending

Draft text and attachments belong to their original connection, profile and chat. Navigation and restarting Wing preserve unsent work. Send moves the submitted message into the outbox before contacting Hermes, leaving the composer available for another draft.

If acknowledgement is lost, that outgoing message pauses for review and is not automatically resent. A missing chat can retain its saved draft; recovering it into a new chat requires a confirmed missing conversation and an explicit Send. See [Drafts and outgoing messages](DRAFTS_OUTBOX.md).

Busy-chat choices are explained in [Composer actions](COMPOSER_ACTION_GESTURE.md). Queued follow-ups stay separate from the current draft.

## Edit, restore, regenerate and branch

Use the pencil in a sent user message's footer to edit it. Editing needs a connected, idle chat. **Replace and resend** confirms replacing that turn and later history; unchanged or empty text cannot be resubmitted. A rejected correction remains available to review or retry. Unrelated composer work is preserved and queued follow-ups pause for review.

**Restore checkpoint** confirms rerunning the selected saved prompt and replacing that turn and later history. It can interrupt an active turn. A refusal preserves the prior conversation; an uncertain outcome requires checking history before trying again.

**Regenerate** replaces the answer in the same chat. **Branch/Fork** creates a separate conversation through the selected saved answer, preserving the original. These are saved-answer actions, rather than composer controls. If a created branch cannot be fully verified, Wing keeps it reachable and explains the incomplete result. See [Server chat relationships](SERVER_CHAT_RELATIONSHIPS.md).

Fork requires a connected, idle source chat. It copies history through the
selected saved active answer; later replies are not included in the branch.
After context compression, the branch carries the summary and active messages;
archived messages remain in the original chat. Tapping
Fork opens **New chat** immediately, with a Wing loading indicator until it is ready or an error with Retry. Regenerate requires
an idle chat.

Find's historical context view is read-only. Edit and Restore apply to saved human prompts, not internal notices.

## Attachments

Saved messages show their user-facing attachment references without repeating expanded file context. Uploading establishes that a file was staged, not that the model read it. Hermes can reject a file reference outside the conversation's working folder. See [Files](FILES.md) for limits and result actions.

## Models, context and reading

The model selector offers the connected server's models and supported reasoning options. Session controls apply to the current chat; model defaults in Administration apply to new chats.

While settings are being saved, the header shows progress and Send waits for
confirmation. You can keep editing your draft. Fast and reasoning changes keep
the reported context percentage visible.

The context ring uses reported server usage or a labelled estimate. Unknown usage is not shown as zero. Its warning thresholds are 65% and 85%.
Tap it to fetch the token composition, including while Hermes is working. Live
token totals keep updating without clearing the last composition estimate.
If a breakdown read fails, the panel keeps known values and offers Retry.

Messages show a local date/time in the footer when available. Long-press it for the full value. Copy at the upper right copies only the message. Newly sent messages may use their local submission time until saved history arrives.

A saved reply can show an approximate time beside **Used N tools**, measured from your saved sent message to the final saved reply. It includes thinking and tool work; missing timestamps leave it unavailable. See [Tool activity](TOOL_ACTIVITY.md#activity-timing).

Tables open as wrapped grids, scrolling horizontally when too wide. Their icon
controls switch between stacked header/value rows and the table. Use a table's full-screen icon to enter
conversation reading mode, hiding the composer and portrait context row without
losing the draft. The same icon or Android Back restores it. Landscape combines
the title and context into one header row. Code and literal output retain their
own wrap and copy controls. Long content can be read separately and returned to
the latest conversation. [Execution and search](EXECUTION_FIND_AND_OUTPUTS.md) explains Find and Activity; [Output viewers](OPENING_OUTPUT_FILES.md) covers files.

### Selecting text in scrolling previews

You can select and copy text in expanded tasks, activity details, code and
conversation history. Selection handles appear for endpoints currently visible
in the reader; scroll to bring another endpoint into view. Select all and Copy
keep the complete selected text, including text outside the preview.
