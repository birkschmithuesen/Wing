# Related chats and answer changes

**Regenerate** replaces an answer in the current conversation. **Branch in new
session** creates a separate chat through the selected saved answer, preserving
the original. The composer commands `/branch` and `/fork` branch through the
latest saved assistant reply; an optional argument names the new chat.

Fork requires a connected, idle source chat. The branch includes only history
through the selected saved answer and leaves the original conversation intact. Tapping the answer's branch
action opens **New chat** immediately, with the Wing loading indicator while
the fork is prepared. If it fails, use Retry or Back.

**Restore checkpoint** on a saved user prompt changes the existing chat instead.
After confirmation, it replaces that prompt and everything after it, then reruns
the prompt. It can interrupt ongoing work and pauses the unsent queue. If the
restore cannot be confirmed, reconnect and check history before trying again.

A parent-chat link appears when Hermes supplies that relationship. It opens
within the original connection and profile. Parent links can describe other
relationships besides branching; they are not a list of previous answer
versions.

Wing does not offer synchronized history of superseded answers. Regeneration
leaves the replacement in saved history. Use a branch when you want to keep the
original conversation and explore an alternative.

See [Conversation actions and reading](CONVERSATION_ACTIONS_AND_READING.md).
