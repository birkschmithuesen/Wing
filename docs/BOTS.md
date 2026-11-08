# Bots

Open **Bots** from Wing's side menu to browse profiles from your saved Hermes instances. Bots and Groups have separate tabs and search. Bots show the most recent activity first, including conversation and background-worker activity. Bots without an activity timestamp appear last; pins break timestamp ties. Pinned groups lead their list. Names and message previews sit on the left, with saved artwork on the right. The floating + creates a bot or group for the selected tab. Status refreshes every ten seconds while Bots is visible. Known group messages refresh every thirty seconds. Groups created elsewhere appear when the background watcher observes them; the fallback discovery scan runs every five minutes. Usable lists refresh quietly.
Wing's feather pulse appears when initial loading prevents you from using the
list. It sits at the right of the instance row, without covering or moving the cards
when loading finishes.

Tap a bot's avatar to edit its appearance. Tap its name or message preview to open its continuing **Bot Chat**. Back returns to the same tab and search. Bot Chats use the usual conversation screen, showing its saved avatar to the left of its display name when available. Tap that avatar or name in the chat header to open Bot settings. Back returns to your conversation with its draft intact.

Messages received from other bots use left-aligned bubbles tinted from each
sender’s avatar color, with the same readable text and timestamp styling as
group discussions. Replies from the bot whose chat is open use that same
message design: a framed avatar across the top-left edge, the sender name, and
a colored footer with the timestamp and an icon-only Copy action.
Spacing keeps each floating avatar clear of the preceding reply’s timestamp
and Copy action, including consecutive bot replies.

The chat screen opens immediately after the tap. Wing's feather pulse appears
while the conversation loads. You can go Back during loading; a failed load
offers Retry in the chat screen.

Explicitly selected classic shapes blink and move in the Bots roster and the
open Bot Chat header. The status Wing pulses while work continues. Pictures
and avatars without an explicit saved shape choice stay still. Select a shape
in the appearance editor—even the currently displayed shape—to save that
choice in Hermes and enable its animation. Motion respects reduced motion and
pauses when hidden or backgrounded. Recents previews and message avatars stay
static.

The roster shows **Running** for live chat turns and background workers with
recent Hermes heartbeats. The Running status keeps its Wing pulse and
expires after 150 seconds without a heartbeat. **Needs input** takes precedence
when a live chat is waiting for you.

Members of a running discussion show **Group running** with a work Wing. This identifies participation in an active room; Hermes does
not report which member is currently writing. Individual Running and Needs
input states keep their priority. A completed or unavailable room clears the
group indication.

Once a Bot Chat conversation identity is confirmed, previously loaded messages
remain readable while Wing checks for updates. The header shows progress until
that check finishes. If refresh fails, the saved messages remain visible with
Retry. Returning to retained reading preserves your place; Latest shows messages
received while you were away. A conversation without retained reading opens at
the latest message.

Bot Chats stay hidden from the default Chats list. Enable **Show automated chats** in Chats to reveal them, or open them directly through Bots. Displayed Bot Chats show a small version of the bot's avatar before their name. Cached names and avatars appear immediately while Wing refreshes them. On a first read, the name appears as soon as it is known, while the saved avatar loads. Other conversations retain their saved titles.

In Chats, long press a profile icon beside the connection name to open that
profile’s Bot Chat. A normal tap filters the list. Back returns to Chats with
the existing filters.

Bot Chats have no projects; their header shows only the instance below the title.

## Profile options

The row menu offers View screen, Pin/Unpin, Hide bot/Show bot and **Bot settings**. The roster menu offers Show hidden bots. Bot pins and appearance synchronize through Hermes; group pins are saved on this device.

Bot settings contains appearance, configuration editors, MCP connectors, Duplicate bot and profile management. MCP connectors opens the selected bot's connector inventory, authentication and access controls. The display name is separate from the underlying profile name. The default profile can change its display name but cannot be deleted or have its underlying identity renamed.

Creating a bot uses the instance's launch credentials and model defaults, as explained before creation. Duplication excludes channel bindings to avoid taking over messaging channels. Settings always apply to the chosen instance/profile, without switching the currently selected chat.

Recents cards show each canonical bot chat's saved name on the left and avatar
on the right before you open it. Group discussions appear in the same last-message
order, with their room artwork or member avatars. Groups appear as soon as their
details load, while bot status and avatars continue loading independently.
Unread replies show a green New answer dot; reading the latest visible discussion
messages clears that cue. Appearance is prepared while the cards are still and shared with the
chat header; opening a card is not required to identify its bot.
The swipe view prepares the current card and its neighbors first, then extends
outward. Ready screenshots appear individually while the remaining chats and
bot details continue loading.

Appearance supports a display name, eight shapes, twelve profile hues, automatic color, image upload/removal and generation through that profile's configured image provider. PNG, JPEG and WebP uploads must fit the 2,000,000-byte avatar limit.

Valid edits save automatically after a short pause. Back finishes pending saves; if saving fails, choose Keep editing or Discard. **Reload saved appearance** keeps edited fields while updating untouched ones. A conflict with another client's changes keeps your draft and asks you to reload/review before retrying. Choosing a shape after an uploaded image clears the image.

## Discussion groups

Group discussions show their icon beside the title, using the same header,
message formatting and composer in the chat and its Recents preview. Swipe
sideways with two fingers to switch conversations, or pinch inward to browse
Recents cards. Neither gesture requires opening Recents first.

Each bot's message bubble uses a soft shade of its saved avatar color, with a
pastel fill in light mode and a muted dark fill in dark mode. Matching bot colors
receive slightly different shades. Your messages keep the selected theme color.
Sender names and avatars identify each bot alongside its bubble color.

Beneath the title, the instance uses the same saved icon and status LED as the
other screens. Tap the icon/LED for connection details or the instance name to
switch instances. The people icon opens the group members. The instance icon and
LED stay in the standard header position while you type.

Tap the microphone in the group message box to dictate, using the voice-input
choice from App settings. Stop finishes the recording; Cancel keeps your draft.
Recognized text replaces the selected text or inserts at the cursor. Review it
before sending. Finish or cancel recording before pinching into Recents.
Leaving the discussion or backgrounding Wing cancels recording.

Create a hosted **Discussion** with 2–6 bots from one ready instance. Hermes runs the discussion and can continue while Wing is backgrounded. Type `@` anywhere in your message to choose a frozen room member or `@everyone`. Search by the bot's name or Hermes handle; selecting Pace inserts `@Pace`, while Wing retains its canonical Hermes identity. Members show their saved bot avatars when available; Everyone uses a group icon. Tap a group’s icon in the Groups roster to open its editor directly; tap its name or message area to open the discussion. Tap the group’s icon or name in the discussion header, including discussions opened from Recents, or choose **Edit group** from its roster actions to change its name, icon color or picture. Upload, generate or remove the picture, then use the checkmark to save to Hermes. Membership and the Hermes instance are fixed when created. Rooms also offer stop and disband.

Tap a member’s avatar or name in **Edit group** to open its Bot Chat. Back
returns to the editor with your unsaved changes.

In an ordinary chat, `@` anywhere in your message offers agents from the same Hermes server with their
saved bot avatars when available. Search also matches saved bot titles; selection
inserts the readable name. Names with spaces use quoted editable text. Duplicate
names include a handle to distinguish them. Commas, quotes and brackets delimit bot names;
hyphens and underscores remain part of the name. A mention
identifies the agent to the current conversation; it does not forward your
message or switch chats. Contact depends on whether the current chat has
`message_agent`. If a selected profile is removed or renamed before dispatch,
Wing pauses the message for correction. Changing its display name is harmless.

In chats and discussions, reference suggestions refresh after a brief pause in
typing (300 ms). The previous rows stay visible while the next results load,
keeping the composer steady. Select a row once the refresh finishes.

Tap member rows to add 2–6 bots. Picked bots move into their own strip above
search, with a remove icon for each. Search by name or @handle to find bots to
add; removing a picked bot returns it to the list. Leave the
name blank to use the selected bots' names, or enter a name of up to 64 characters.
Choose a Hermes instance when several are ready.

The default room icon overlaps the selected bots’ avatars inside a square frame
with a random color from Hermes/Wing’s usual palette. Three members form a
triangle, four a square, five a pentagon and six a hexagon. The frame color stays fixed
while you edit and is saved on Hermes. Renaming the room keeps its member avatars.

Upload a room picture, generate one from a description, or remove it. Wing
remembers your edited description for that room on this device, including after
closing the popup, failed generation and restarting Wing. Clearing it keeps it
empty until you enter another description. It does not sync to other devices.
Generation uses the chosen instance's default profile image provider and accepts
generated originals up to 8 MB. Uploads accept PNG, JPEG and WebP up to 2 MB.
Wing crops a square thumbnail up to 256 px and compresses it
to at most 45 KB for upload. Transparent pictures keep their transparency over
the icon color; detailed transparent pictures may use a smaller PNG to fit.
A checkerboard drawn into the image remains part of the picture.
Creating the group saves its picture on the chosen
Hermes backend; another Wing device connected to that backend can load it.
Removing a picture restores the member-avatar collage. Icons appear in the group list and
conversation header. Desktop uses a
separate room format and does not currently display Wing's hosted-room pictures.

The bottom dock previews your room and keeps Create group above the keyboard.
Creation becomes available with at least two members. If it cannot be confirmed,
the form fixes the room details so you can retry the same group.

Group message drafts save on this device as you type, including selected member
mentions. Leaving the group or restarting Wing restores its draft. Each server
and room keeps its own draft. Sending clears the accepted text; a newer draft
typed while sending stays available.

An unconfirmed send keeps the same message identity for review and retry. A definite Hermes refusal restores the editable text and attachments. Failed attempts offer Retry; unknown outcomes offer Discard with an explicit consequence review. Bounded discussions offer Continue for that exact discussion within the server’s extension limit. Pending approvals stay above the composer while you scroll. The exact command appears in the transcript; request details expand separately. Use the icon-only controls to approve or reject. After the request ends, an **Asked a question** entry inside the usual collapsed **Activity** section stays where it first appeared in the conversation, including after reopening the group. It moves up as new messages arrive and has no dismiss control. Closed means the outcome is unknown; Expired requires a confirmed timeout. You can also answer group approvals from Wing notifications.

Your bubbles show your message without a User label. Bot replies show the
sender's saved avatar and name, formatted text, links, code and timestamps.
Bot and user Copy actions sit in their colored bottom rows. Long bot answers use
the available reading width; your bubbles remain right-aligned and clear of the
framed avatar. Discussions and Bot Chats use the same transcript renderer,
including reading-position anchoring, Latest/New activity navigation, Copy and
message viewers. Bot Chats and Working history use the same streamed reasoning,
tool timeline, Tasks/Agents viewers and working Wing. Group discussions show the
public room messages and room status supplied by Hermes; select a member’s
Working history to inspect that bot’s private activity.

Working history displays received messages before waiting on older pages or live
activity. Activity starts collapsed and loads its contents when you open it.
Live activity arrives separately, with progress in the header while it loads.
Current Tasks and Subagents remain in the bottom dock through waiting and idle
states; refreshing or opening activity keeps the messages readable.

When a bot passes its turn, the discussion shows a **Passed** bubble with that
bot's name, avatar and timestamp. Recents cards include these bubbles. A pass
does not create a New answer cue or a reply notification.

Tap a bot's avatar in the discussion to open a compact card over it, with the
bot's saved avatar and name above three icon-and-text actions: **View working
history**, **Chat directly** and **Bot settings**.
The menu opens over the tapped avatar, showing a single face. The original tile
returns when you close the menu or return to the discussion.

Working history opens with that member selected. Direct chat immediately opens
the bot's private conversation screen, with the Wing pulse while it loads and
Retry there if loading fails; settings apply to its profile across chats.
Working history and settings return to the discussion with your draft and
reading position intact. Direct chat follows the normal Bot Chat navigation;
Back returns to Bots. A direct chat on another saved instance uses Wing's usual
instance-switching flow.
Both use the same icon-only Copy beside the message as normal chats. Type `@` in the composer to choose a
member; the picker inserts at the cursor. The conversation opens
at its latest messages and renders older messages as you scroll up. Your reading
window stays in place as replies arrive; reaching the bottom or using the down
arrow shows those replies. The arrow uses the same motion as normal chats.
Initial loading uses Wing's feather pulse in the upper corner while messages
are unavailable. Existing messages refresh quietly, and loading feedback keeps
the reading viewport fixed.

Pinch inward on the discussion to open the same cards as normal chat Recents.
The group remains mounted with its draft and reading position. Tap its card or
use Back to close the stack. Direct entry from Groups returns to the Bots
screen with Groups and its search retained. Opening from Recents, switching
with a two-finger swipe or entering the card viewport makes **Recents** the
Back destination. Back closes any open card stack first, then leaves the
conversation. Earlier conversations are cleared from the navigation stack.
Cards do not mark group messages as read. New group replies immediately show
New answer in Recents and can trigger the conversation arrival cue. The badge
clears when you reach the reply in the discussion.

New group messages update Recents as soon as Wing observes them, including rooms
last used more than a day ago. Reading a reply clears New answer; notification
permission does not control the unread badge.

Recents and the card browser share a cached list and screenshots. Reopening uses
the saved view while background reads refresh it. You can swipe to another
conversation while one is opening. If a group or profile refresh fails,
its known conversations stay available with an error; a confirmed removal
deletes the entry.

Group cards and open discussions use the same saved member artwork. While a
member image loads, its known identity stays available; unknown member positions
stay empty. Completed avatar reads update the card without rereading messages.

Tap the people icon under the title for a compact member list anchored beneath
that button, with saved names and avatars. Tap outside or use Back
to dismiss it. Without a saved room picture, the conversation shows its
member-avatar collage.
The ellipsis menu contains Member activity, Shared settings, Refresh and Stop.
Shared settings edits purpose, shared notes and routing for future discussions.
Purpose allows 500 characters and notes allow 4 KB of UTF-8 text. Everyone gives
each member a turn on an unaddressed message. Lead lets a selected member choose
who replies; an invalid selection leaves the lead alone. Auto makes an extra
model call to choose recipients; a failed or invalid selection falls back to
everyone. Choose Auto explicitly if you want this additional model call. Mentions
select recipients directly, and scheduled posts follow their own routing.

Retry targets one failed member/task attempt. Discard is available for a stock
local attempt whose outcome is unknown; it abandons that attempt so the group
can recover. It does not undo side effects, prove that nothing happened, or stop
a running process. Continue grants more rounds to the exact discussion that
reached its limit. Its explanation shows the extension number and server limit;
stopped, superseded and exhausted discussions cannot continue. Each new message
starts its own discussion thread.

Stop group work also remains available during Send. Wing waits for the matching
saved Stop event before permitting Continue. Repeating Stop creates a fresh
fence for work admitted since the previous request. Retry, Discard, Continue and
settings controls follow the methods advertised by that connection.

Approvals use the same command review as normal chats and notification review.
The exact command appears in the transcript; expand request details for the
explanation. While reading older messages, tap Latest to reach the review.
Refresh rereads messages, activity and approval state without restarting bots.
Automatic refresh stays quiet; explicit refresh uses the header Wing pulse.

While work is active, the empty composer offers Stop; entering a draft offers
Send. Sends and controls show the header Wing until settlement. The compact
status shows each active member’s queued, running or stopping state and tool.
Open Group options → Member activity for reported start/last activity times;
Raw details keeps the exact member, thread and round identifiers. These are server
observations; polling does not update their timestamps or prove a bot has
stalled. Confirmed work keeps the shared working indicator. Recognized mentions
display as bold, colored `@Name` text; Copy preserves the original message.

Internal group workers stay out of the default Chats list and chat notifications,
so they do not produce `Group: <UUID>` alerts, including after opening a worker
from an earlier notification. Replies to bot-to-bot messages in Bot Chat are also
silent; replies to your own messages still notify you. Monitoring follows the
shared discussion across pauses between bot turns. New shared replies update one
notification per group; the latest reply replaces the previous one. Tap it to
open the discussion. Reaching the reply clears it. Answer group approvals in the
discussion or its notification. Unresolved requests in ordinary chats stay pending when newer replies
arrive.
On Android 12 and later, the group transcript supports system scroll capture;
the composer and keyboard are outside the capture area, and capture restores
your reading position.

## Bot screen

Choose **View screen** from a bot’s row menu to watch its live desktop. The bot
needs a supported Linux host with the Hermes Bot Screen components installed.
Start/stop controls target the selected bot; stopping is unavailable while a
human holds control.

The connection dot beside the instance name follows that instance's live status.
Tap its icon or dot to inspect connection details.

Use the control icon to take control. If another device has control, Wing asks
before replacing it. Tap where you want to click, double-tap to double-click,
hold to right-click, or double-tap then hold and move to drag. One finger pans
the magnified view; pinch to zoom and move two fingers together to scroll.
The persistent side strip also scrolls the desktop at the last touched point.

Four main icons open the phone keyboard, paste the phone clipboard, reveal More
controls and change ownership. Extra keyboard controls include Enter, Tab,
Escape, Backspace, arrows and one-shot Ctrl/Alt/Shift modifiers. Paste transfers
plain text and invokes Ctrl-V without pressing Enter. Its progress indicator
stays visible until the remote application requests and receives the text;
an unaccepted paste shows a retryable error. More contains screen refresh,
start/stop, fullscreen, panel visibility and gesture help.

Turn the phone sideways to enter full screen automatically. The agent panel
sits beside the desktop in landscape and below it in portrait. When opened from
a chat, it shows the latest assistant message or pending request. Open
**Conversation** to read or queue a message without replacing the main chat's
draft. Answer formal approvals and private-input requests in the main chat.

Hand control back with an optional note asking the agent to continue. Wing
releases control before queuing the note. If sending fails, the note stays
available and Wing explains that control was already returned. A screen opened
directly from the roster has no selected conversation and simply returns control.
Closing the screen also hands back this phone's control; if that cannot be
confirmed, Wing keeps the screen open for recovery. Backgrounding or losing the
connection leaves control held until you explicitly hand it back. Taking or
releasing another device's control requires confirmation.

Wing does not currently configure RoomLink peer groups, desktop Direct
conversations, pet avatars or automatic screen opening. Hosted groups use bots
from one instance, although the bot roster and ordinary settings work across
saved instances.

## Bot messages and delivery

Messages from other bots appear on the left with their name, avatar when available,
formatted text and time. Copy copies the message body. Replies from the bot you
are talking to stay visible as normal answers. Received bot instructions cannot
be edited or restored as your own prompts.

In Activity, **Message agent** shows the sent **Message** and its **Queued**
acknowledgment. When Hermes returns the matching delivery result, Wing appends
**Exchange complete** with the reply below it. Each available timestamp appears
on the right in your local time. Queued means handed off, not delivered.
Pending, unknown and failed outcomes retain their own labels; avoid resending
when the outcome is uncertain. Raw details keeps the exact receipts.

An unmatched “Bot delivery process finished” notice stays separate. Expand
Output to inspect the runner's command and result.

## Group replies and activity

Use the reply icon below a message to continue that discussion thread. Wing
shows the selected message above the composer and adds a mention when replying
to a bot. Cancel reply clears the thread selection. An unconfirmed send keeps
its selected thread through retry and reopening.

The shared discussion contains the room’s public history. Open **Group options →
Member activity** for reported member progress. Private group-worker transcripts
are not exposed by the current canonical Hermes API or Desktop group view.

New group offers only local bots the gateway currently permits as members.
Create checks the list again; if eligibility changes, reopen New group to choose
members again. Existing groups retain their fixed membership.

[Administration](ADMINISTRATION.md) · [Chats](CHATS.md)

### Shared conversation presentation

Normal chats, Bot Chats and groups share page framing, transcript layout, reading
mode and the responsive composer. Groups retain their room-specific execution,
member mentions, reply threads and available actions.
Reading mode hides context and footer; Back restores them before leaving.
