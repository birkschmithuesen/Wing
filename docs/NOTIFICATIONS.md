# Stay in the loop

Wing can alert you when a connected chat finishes or needs an answer. It uses Android notifications while it monitors active work; Hermes continues accepted work on the server when you leave Wing.

## Turn on alerts

Open **App settings → Notifications** and allow Android notifications. Choose the reply and attention alerts you want. **Test notification** checks that Android can display an alert on your phone. If **Allow background activity** appears while Wing is watching work, tap it and approve Android's battery exemption request for background delivery.

At startup, Wing checks its battery exemption and asks Android to approve background activity if it is missing. Approve the system request to allow background delivery. Once granted, the startup prompt stops. If you decline, Wing remains usable in the foreground and asks again on the next startup.

Tap an alert to open its chat or group discussion. The tapped alert clears immediately while the conversation loads. A newer reply arriving during opening does not cancel your tap. When the full command is visible, **Once** and **Session** send your decision directly; **Deny** rejects without another confirmation. **Always…** opens a review of permanent permission. A truncated command offers **Review…** and **Deny**. Android requires unlocking before an approval action. You can hide message previews in Wing's notification settings.

Turning previews off also makes earlier allow actions require review. If an old alert no longer opens, reopen Wing to review the current request in its chat.

Monitoring stops when the work it is watching ends. If you restart the phone or force-stop Wing, reopen it to restore its connection. Very short turns in chats you have not opened may not produce an alert.

[Good to know](KNOWN_LIMITATIONS.md) · [Notification details](BACKGROUND_NOTIFICATIONS.md)

Group approvals use the same attention notifications. The checkmark allows once; the cross denies. The request stays visible while its decision is sent. Group approvals offer only the scopes Hermes permits: once or deny. Tap the eye to review a long command in the discussion.
