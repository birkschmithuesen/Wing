# Navigation, profiles and projects

## Find your work

The drawer opens Chats, Recents, Bots, Hermes instances, App settings, Hermes administration, Hermes health and Hermes analytics. Projects are organized within Chats.

Recents and Bots show the shared Instance component below their title. Tap the
instance name to choose an instance, or its icon and connection indicator for
connection details.

Chats browses profiles on the selected connection. Search sits above Status, Profile and Project filters. Each filter allows multiple selections; the cross clears the filters.

The chat list's menu contains **Group by**, **Sort by**, **Show details**, **Show automated chats**, Collapse/Expand all, Mark all as read, Archived/Active chats and New project. Grouping starts with Project and sorting with Updated. Pinned chats appear once, followed by group previews. **Show more** reveals ten more chats. Token totals include matching chats outside the visible preview when the list is complete.

The floating pen creates a chat. Wing asks which profile to use unless exactly one is filtered or available. Changing the profile in Wing does not change another client's selection or move accepted work to another profile.

Back returns through the current viewer, editor or Recents stack, then from a conversation to its originating Chats, Recents or Bots screen. At the workspace root it opens the drawer before exiting. Navigation preserves drafts and open work.

Page loading and manual refresh show a pulsating Wing in the header. During
that wait, an existing conversation work Wing stays static and resumes pulsing
when loading finishes. Reduced motion keeps the Wing static.

## Search and visibility

Search finds chat titles and server message matches across profiles, including archived matches when they fit the selected scope. Message search has a server limit of 100 results per profile. Incomplete loads retain readable rows and offer Retry; a partial list is not a complete archive search.

**Show automated chats** starts off. It hides scheduled, tool, subagent, kanban and one-shot chats from Chats until enabled, including hidden Bot Chats. Recents always excludes these automated sources while keeping user conversations that have background work.

Unread status comes from Hermes. Hidden Bot Chats compare the latest saved message with the server read timestamp; a missing timestamp keeps the chat unread. Opening a chat and loading its history marks it read; reconnecting alone does not. Filters and display choices are saved per connection on this device.

## Projects

Create a project with an absolute folder path on the Hermes host. Repository discovery can scan for repositories, or you can enter the folder manually. Project menus offer New chat, Rename, Appearance and Delete. Deleting a project removes its organization, leaving chats and host files intact.

Inside a conversation, tap **Unassigned** or the project icon/name to choose a destination. Search by project name or working folder. Moving changes the chat's working folder and project association; it does not move files or transfer the chat to another profile. The chat must be idle and its destination verified. A failed move remains available for review or retry.

The server name and connection indicator open connection details separately. See [Connections and updates](CONNECTION_DIAGNOSTICS_AND_VERSIONS.md).

Deleting a chat requires confirmation and a verified idle conversation. Busy or uncertain state can block deletion. If an operation's outcome is uncertain, review the server state before repeating it.
