# Sharing into a draft

Share text, links, images, or files to Wing, or use Camera, Photos, Files, and
supported clipboard-image paste in the composer. Incoming shares open a review.
With multiple connections, choose the server first, then a profile and a new or
existing conversation. Older chats can be loaded from the review.

**Add to draft** prepares the content and preserves existing text, attachments,
and queued messages. Shared text is appended with a blank separator. Send remains
a separate action. A failed preparation leaves the destination draft intact.
Cancelling keeps the share available through Home's Review control; Discard
explicitly removes it. A failed new-chat attempt reuses the created chat on retry.

Pending shares survive app restart. The queue holds up to ten shares and 128 MiB
of files; one share allows 40 files, 128 MiB of files, and 256 Ki characters of
text. Unreadable or oversized input fails visibly as a whole. If saving the draft
succeeds but clearing the pending share fails, open the saved draft and discard
the duplicate pending item from Home.

## Photos, camera, and clipboard

Images are prepared for sending and private metadata is removed. Unsupported or
oversized images show their rejection reason without sending anything. Malformed
orientation metadata can leave an image in its stored orientation. Prepared
images have a 25 MiB limit.

Camera opens your phone's camera app. A completed photo returns to the original
chat's draft and preserves existing text and attachments. It is not sent
automatically. If that chat cannot be reopened or preparation fails, the photo
stays pending for review or retry. Cancelling removes only that capture.

Clipboard-image reading begins only when you choose Paste. A stalled read times
out; cancelling preparation releases your wait. Existing draft content remains
intact, and late results cannot appear in another chat. Copy the image again to
retry. If the provider is still busy, wait before another paste.

## Interruption and recovery

After an interruption, content already added to a draft can also remain pending
for review. Check the draft before adding it again. A copy interrupted before
Wing saved the incoming share may need to be shared again.

If the original chat has expired, **New chat with recovered draft** preserves
its unsent content in a new chat. Recovery can leave two copies after an
interruption, so review before sending. The queue remains paused and uncertain
delivery stays marked. Missing files remain visible for removal or reattachment.
See [Conversation actions and reading](CONVERSATION_ACTIONS_AND_READING.md).

## Sharing from Wing

Configuration backups, output files, and skill text share one Android share
operation at a time. If another sheet is open, finish or dismiss it before retrying.

Shared files can remain in Android's provider cache until a later share clears
it, Android removes it, or you clear Wing's cache in Android Settings. A receiving
app can save its own independent copy. Closing the chooser does not guarantee
that every copy was removed. Keep this in mind when sharing plaintext backups
or other sensitive files.
