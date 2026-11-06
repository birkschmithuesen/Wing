# Connections, diagnostics and backend updates

Start with [Getting started](GETTING_STARTED.md) for your first connection and [Self-hosted setup](SELF_HOSTING.md) for dashboard authentication and proxy help. Wing needs the Webapp served by the Hermes gateway. A standalone Dashboard URL cannot open chats.

## Returning to Wing

Wing attempts to restore the visible workspace connection when you return to the app or open a disconnected workspace. Temporary failures trigger automatic retries; **Retry connection** remains available if recovery fails. Returning also retries a workspace that failed during its initial loading. Recovery preserves drafts and does not automatically resubmit a message whose delivery is uncertain.

A **Chat address needs changing** status means the server is reachable but its endpoint does not support Wing chats. HTTP health alone cannot make this LED green. Open the instance menu → **Edit instance**, enter the gateway Webapp base URL, then check and save. Reconnecting to the same standalone Dashboard cannot fix this mismatch.

Changing a connection's address or credentials replaces its access configuration. Check that you are opening the intended saved instance before sending work.

Moving between chats, Bots, administration and Versions reuses the dashboard
sign-in for that saved connection. Closing a screen preserves the sign-in.

The Wing pulses in the header during reconnection, without a status text row.
If recovery fails, tap the connection status icon and choose **Retry connection**.

## Access headers

Authenticated proxies can use **Sign in → Custom setup → Access headers**. Most connections need only the gateway Webapp URL and login. Leave a replacement blank to keep a saved value, enter a replacement explicitly, or remove it. Header names must be unique ignoring case; names and values must be single-line. Managed authentication headers cannot be overridden.

Access secrets use secure device storage. They are included in explicit configuration exports, which can be encrypted with a passphrase. See [Configuration backups](CONFIGURATION_BACKUPS.md).

Wing refuses dashboard redirects. Enter the final address and path directly. Reads and downloads time out when the server stops responding. Some operations that change server state can remain pending longer; a read timeout does not prove that a preceding action failed.

## Diagnostics and versions

Connection diagnostics distinguish dashboard access, configured providers and resolved credentials. A credential result does not prove that a model request will succeed or that quota is available. [Hermes health](ADMINISTRATION.md#health-checks-and-diagnostics) offers profile checks, Doctor, security audit and logs.

App settings shows the installed Android version/build separately from the backend version. Releases and Changelog open Wing's release information. Android app updates are not downloaded or installed automatically.

## Update Hermes

Versions & updates can check for a server update and request it explicitly. **Changes in this update** shows available commit summaries, with a partial-history notice when needed; the server returns at most 20 summaries.

The screen checks automatically when opened. The header Wing pulses and the circular update icon rotates while the
check runs, without a duplicate loading caption. The installed version appears
as soon as it is available. Unknown availability is shown only
after a completed check provides no answer; a failed check offers another check.

The server card shows its update channel. Use the tuning icon to choose **Stable
releases** or **Main branch**, then the checkmark to save. This changes which
updates the whole server follows; it does not install an update. Wing checks the
saved channel immediately. A failed save keeps your selection open for retry.
Named preview channels and custom branches are displayed when the server reports
them; Wing does not provide a preview-channel catalog or change custom branches.

Stable follows published releases and may have no commit count or changelog.
Main shows commits behind its branch when Hermes can count them. A build newer
than stable is identified separately, and moving back to an older release has an
explicit warning before updating. When Main reports an update without a commit
count or change details, Wing explains that Hermes could not compare the
installation with upstream. If the check fails, Wing shows the server's
explanation and leaves the update action unavailable. Unverified channel metadata
also blocks updating. Check again before proceeding.

After confirmation, starting status and a collapsed **Update logs** viewer appear
immediately. Wing follows progress automatically while this screen remains open.
Expand the viewer to read output with the newest lines at the top. Long output
scrolls inside a viewer sized for 16 text rows, scaling with your text size.
Short logs use only the space they need. The single sync button stays at the
right of the action row. During an outstanding update it offers **Check update
progress**, including retry after a restart or disconnection; this does not
repeat the update request. Before an update and after it finishes, the same
button offers **Check for updates**.

Leaving the screen does not cancel an accepted server update. If acknowledgement is lost, the outcome stays uncertain; check its status and version before repeating the request. Request acceptance alone does not mean the update completed.

When updating several configured hosts, review the targets and each host's result separately. Different addresses can refer to the same physical server. A messaging-gateway restart is separate from a TUI restart; Wing does not offer a verified remote TUI restart action.

Hermes Cloud manages updates for its instances. Wing still shows the installed
server version and lets you refresh it, while omitting host updater and channel
controls. Self-hosted connections retain the exact-target update flow.
