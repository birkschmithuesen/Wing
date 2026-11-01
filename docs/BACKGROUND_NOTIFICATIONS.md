# Background notifications

Wing can keep watching connected work while you use other apps. Its ongoing Android notification shows **Watching chats**, with each chat's name and status, such as **Research bot · working**. Bot conversations use the bot's saved name once its identity loads, and the profile's display name while it is unavailable. Replies and requests for input appear as separate chat alerts.

The summary shows up to three conversations and a count of the others. Unnamed
chats include a short session ID so they can be distinguished. A temporary
connection loss shows **reconnecting** for unfinished work; Wing keeps watching
all those chats, including ones omitted from the summary.
Opening or initializing a chat alone does not start monitoring. Once a successful
live-session check confirms that an old runtime is gone, Wing stops watching it.
That does not generate a reply alert or claim its task finished successfully.

## Enable monitoring

1. Connect Hermes and allow Android notifications in **App settings → Notifications**.
2. Enable the reply or attention alerts you want. Monitoring starts automatically when a chat begins work while Wing is visible.
3. If Wing reports battery restrictions, choose **Allow background activity** and approve Android's exemption prompt.

There is no separate monitoring switch. Idle chats do not start monitoring. Monitoring uses additional battery and stops when the watched work finishes, after posting final alerts. Another working chat or live child task can keep it active. Disabling both alert categories or revoking notification permission stops it.

Connected group discussions also keep monitoring active while their bots work.
The ongoing notification shows each discussion's name and status. Pending
approvals take priority over unread replies and offer icon buttons to allow
once or deny. Tapping the notification opens the discussion.
Group workers do not send ordinary chat reply alerts.

Android force-stop, process termination, reboot, connectivity loss and manufacturer restrictions can interrupt delivery. Reopen Wing after restarting your phone or terminating its process. Work started elsewhere cannot wake a stopped Wing app. Accepted Hermes work continues on the server.

## Choose alert content

Notification settings has independent reply and attention switches, **Show message previews**, and a permission/test action. **Test notification** checks Android posting, rather than delivery of real server events.

Alerts show their chat and connection/profile. Reply previews omit reasoning, code blocks, tool output and URLs. Turning previews off keeps the chat name and short status. Secure-input alerts use fixed text. Lock-screen visibility also depends on Android settings.

Unanswered requests take priority over unread results. When several requests are pending, they are shown in order. Dismissing a notification does not answer or deny the request.

When Wing confirms that a question or approval was answered, it clears that request's alert. This also applies to answers sent from desktop. After restarting Wing, connect to the original server so it can check restored alerts. A failed connection leaves them visible until the check succeeds. An unread reply can remain after its question clears.

## Answer approvals and open chats

Approval actions require unlocking the phone. Short complete commands offer Once and Deny. Review opens the request in Wing, including Session and Always choices when the server offers them. Session applies to matching commands for that session. Choose Always explicitly in Wing to allow matching commands permanently. Long or incomplete commands, or hidden previews, require review in the app.

The alert stays visible while an answer is being sent. A failure keeps the request available; changed or expired requests require reopening the chat for review.

Chat alerts use Android conversation notifications. Tap an alert to open its original chat or shared discussion. The ongoing monitoring notification opens the watched conversation when there is one, including a shared discussion. With two or more watched conversations, it opens Recents. Reading the latest answer in Wing clears that result's alert. Opening older history does not. If newer history has arrived, an older alert may open the latest available answer.

## Delivery limits

Wing monitors connected work and reconciles reported changes while it remains connected. It does not subscribe to every historical chat. Very short work in unopened chats, missing server events and child-only activity can leave alert gaps. Temporary disconnections retain drafts and recent reading, but do not guarantee replay of every missed outcome.

Opening a chat refreshes its server state. Notifications help you return to work; the conversation on Hermes remains the record to check. Unsent follow-ups still need a running, connected Wing client. See [Queues and pending input](SUPERVISION_AND_QUEUES.md).
