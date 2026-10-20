# Pforte notifications and Nachtruhe

## What it does

When a connected Hermes server offers the porter wake plugin, Wing shows a
"Pforte: neue Nachricht" notification on the existing attention channel. It
occupies a single slot, so a new notice replaces the previous one.

- **Öffnen** (tapping the notification) opens the most recent pforte session and
  shows an in-app notice sheet.
- **Später** postpones the notice. In the in-app sheet, a long press or the snooze
  icon opens a chooser with „in 2 Stunden“ and „morgen“.
- In trial mode the notification also carries rating buttons. Their labels come
  from the server and are shown exactly as sent.

Settings, Notifications, has a „Nachtruhe“ block (quiet hours, „von“ / „bis“).
The server is the source of truth: Wing reads and writes the values there and
keeps no local copy.

## Requirements

- A Hermes server with the porter wake plugin.
- The ntfy app as UnifiedPush distributor, pointed at your own ntfy server.
  No Firebase or Google push is used.

## Stock Hermes

The module is inert unless `GET /api/plugins/porter_wake/settings/quiet-hours`
answers 200. On 404 or 503 Wing does not register an endpoint, shows no
„Nachtruhe“ UI and makes no further porter calls on that connection.

## Privacy

- The push carries no content. Wing fetches the notice from the Hermes server over
  its authenticated dashboard connection.
- Wing registers its UnifiedPush endpoint with a random per-install device id
  stored in secure storage. It is not backed up (`allowBackup=false`).
- The registration is revoked when the connection is removed (including config
  restore or import), when the distributor unregisters, and when the distributor unregisters. When credentials are
  edited, Wing re-probes the server and registers again with the new connection;
  the old server's registration is not deleted.

## Scope exception

This module calls a custom plugin endpoint (`/api/plugins/porter_wake`). That is
an exception to the AGENTS.md "Hermes deployment constraint", approved by Birk on
2026-10-19 for this module only. All code lives in `lib/porter_wake/` and
`android/app/src/main/kotlin/com/tarkilhk/wing/porterwake/`.

## Known limits

Delivery while Wing is closed (the headless engine) is not yet verified on a
device. The connector's WebPush code runs on tink-android 1.23 (runtime
unverified). The connector API and plain-JSON delivery are compile-verified
only and stay unverified until the device handoff.

Go-live assumptions not yet verified on a device: plain JSON reaching the
connector's `onMessage`, network access under Doze, and an `http://` ntfy server
on a tailnet.

## Contract

[Wing push contract](superpowers/specs/2026-10-19-wing-push-contract.md)
