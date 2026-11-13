# Chats and active work

Wing helps you return to the right conversation and keep it moving from your phone.

## Find a conversation

Open **Chats** to search, pin and group conversations. Filter by profile, project or status; use **Recents** to find recent conversations and work that is running or needs input. The selected connection and profile determine what you see in Wing without changing another client's selection.

Choose **Group by** or **Sort by** in the Chats menu. Wing remembers these
choices per connection and applies them as soon as the initial list loads.
After loading, live updates keep rows in place; refreshing or choosing a sort
again updates their order.

The opened chat keeps its confirmed title and project when you return to Chats.
Title updates use the information Hermes already sent. Returning to the list or
refreshing it reads the latest catalog; background chat changes do not rescan it.

Seeing the latest answer in the open chat marks it as read in Chats and Recents.
You do not need an extra swipe.

Tapping a chat in Recents opens its screen immediately; loading and any retry
stay there. Back returns to Recents even while the chat is loading.

Wing prepares Recents in the background once your workspace is ready. Opening
it reuses those results; if preparation is still underway, you can use the
available cards while the header shows progress.

You can open a visible chat while its profile or chat list is refreshing. Wing
opens the conversation and loads its history independently of that refresh.
Back returns to Chats while the conversation is still connecting.

Confirmed ongoing work uses Wing's feather pulse in the row's status slot.
Opening the chat and its actions remain available while Hermes works.

Inside a chat, tap the project name below the chat title to open the project
picker and move the chat. Tap the chat title to open **Rename chat**, or hold a
chat in the list and choose **Rename**. Type a name or tap the AI sparkle beside
the field to generate a suggestion from the conversation. Adjust it if needed,
then tap the checkmark to save. Generation and saving show progress in their
controls; errors keep your draft name available for retry. A new chat needs a
message before AI can suggest a name.

A canonical Bot Chat's avatar and name continue to open **Bot settings**.

Hidden conversations stay out of Chats by default, including a bot's continuing
**Bot Chat**, even after opening it from Bots. Tick **Show automated chats** in
Chat list options to include automated conversations and each profile's canonical
Bot Chat. A displayed canonical Bot Chat has a small version of the bot's avatar
before its name.
Search follows the same visibility choice.

## Send the next idea

Create a chat, choose a profile and send a message. Replies stream into the conversation with code, tables and available tool activity. Your draft and attached files stay in place if you navigate away.

While a reply streams, Activity contains tool calls. Reasoning appears directly
in the conversation between tool runs. The compact bar above your draft shows
subagents and completed/total tasks. Tap either side to open its drawer, then
swipe left or right to switch. Swiping up on either bar opens its category at
compact height; swipe up again to maximize. Swipe anywhere in the panel up to
expand or down to close; at full height, rows scroll back to their top before a
downward swipe closes it. Diagonal
swipes follow the larger horizontal or vertical movement. Tapping the selected
tab or outside also closes it.
Your draft stays in place. Past answers keep their existing Activity layout.

Open a subagent to inspect its trace. Images, file previews, skill documents and
message attachments use the same viewers as the main conversation. Preview,
share and download actions read from that child's chat, including nested children.
Failed image reads offer Retry.

While Hermes is working, the composer can **Steer**, **Queue** or **Stop**. The default action is your choice in App settings; hold and slide the arrow for a one-time alternative. Hermes runs accepted queued follow-ups in order, even after Wing disconnects. Work still stored only on the phone needs Wing to reconnect before it can be submitted.

The queue above the composer starts as a compact count. Expand it, then tap or
hold a message to open its full text and supported actions. Entries needing
review stay visible when collapsed. Steer accepts text only and needs a connected
active turn. Your separate draft stays in place.

## Models, context and code review

Open the model picker, then **More model options → Use profile default** to remove
this chat's explicit model choice. It does not change the profile's settings.
Model cards show applicable plan allowances and reset times when Hermes supplies
them. The context popup identifies a configured maximum.

In an idle chat, send `/compress --preview` to inspect the compression plan;
`/compress` or `/compact` applies it. Wing refreshes history and shows the result.
See [Slash commands](SLASH_COMMAND_SUPPORT.md) for focus and retained-message options.

For a supported local terminal workspace, open **Chat actions → Git review**.
Read changed files, compare All changes or Staged against HEAD, and copy a line
or hunk reference. This view does not stage, revert, commit or push changes.

## Revisit the result

Inside a chat or bot group, pinch inward to open the same conversations shown in **Recents**,
including bot groups. Cards follow message freshness: left is newer, right is
older, with the oldest and newest linked in a circle.
Unread cards carry the same quiet tint as the Recents list.
Soft edge ripples indicate replies or requests for input in other recent
conversations, including while you type with the keyboard open. Reduced motion
suppresses the ripples.
A two-finger horizontal swipe switches to the adjacent conversation directly, including
before the first pinch. Icon-only controls also
support keyboard and accessibility navigation. Opening a group shows its group
chat. Back closes the cards first. Back from a conversation opened through
Recents, a two-finger swipe or the card viewport returns to **Recents**, even
if you never opened Recents from the menu. Direct entry from **Chats** returns
to Chats; direct entry from **Bots** or **Groups** returns to Bots with its
selected tab and search intact.
When you return to
a conversation already loaded in this workspace, its retained messages appear
while Wing refreshes quietly from Hermes; new replies appear when the server
history arrives. If refresh fails,
the retained conversation stays readable with a retry notice. A conversation
without retained history still needs its initial server load, indicated by the
Wing pulse in the fixed header slot beside the instance details.

Sent messages have a compact footer with the date on the left and icon-only
Edit and Restore actions on the right. Copy sits outside the bubble at its
upper-right corner. Edit opens a correction; confirm **Replace and resend** to
replace that turn and all later history in an idle, connected chat. **Restore
checkpoint** reruns the saved prompt without editing it and can interrupt a
running turn after confirmation. Both preserve separate composer work and pause
queued follow-ups. Use **Find in chat** to search older messages, **Outputs** to
browse files, or the answer actions to regenerate or branch into another chat.
Model changes show Hermes warnings before you confirm them.

Copy actions throughout Wing write directly to the clipboard without a bottom
confirmation popup. Android may show its own clipboard confirmation.

Hold a web link in a reply, or right-click it with a mouse, to choose
**Select text**, **Open in external browser** or **Open here**. Selecting text
highlights the link label so you can adjust the selection or copy it.
Set the default destination for regular taps in **App settings → Open links in**.

[Explore Wing](FEATURES.md) · [Conversation details](CONVERSATION_ACTIONS_AND_READING.md)

## Questions and approvals

When Hermes asks several clarification questions together, stage all answers in
one form and confirm once. If a later answer fails, confirmed answers stay locked
and you can correct or retry those remaining. Eligible cut-off replies offer
**Continue**; model or connection recovery does not automatically resend a prompt.

Completed questions and approvals appear inside the conversation's usual
**Activity** section as **Asked a question**. Both disclosures start collapsed.
Details start collapsed and show the question, any command, and its outcome in
the shared Activity card. Commands retain their exact source in the standard
code viewer with Copy, wrap and full-view controls. Approvals report Approved
or Rejected; these outcomes describe permission, not execution success.
Confirmed timeouts report Expired, withdrawals report Cancelled, and Closed
means the outcome is unknown.

Completed approval and secure-input entries stay where their requests first
appeared and move up as messages arrive. There is no dismiss control.
Ordinary clarification questions retain their native Activity receipt, including
choices and answers, without an additional history row. Secret response values
are never saved in request-history entries.
