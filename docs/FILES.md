# Bring files into Wing

## Add something to a chat

In the composer, choose **Camera**, **Photos** or **Files**. These actions are available whether you opened the chat from the chat list, a notification or a health alert. You can also share text, a link, an image or a file from another Android app into Wing. Incoming shares open a review so you can choose the connection, profile and chat. Nothing is sent until you tap **Send** in the chat.

With **Camera**, confirm the picture to add it to your current draft while keeping the chat open. You can take another picture to add it alongside the first. Cancelling the camera leaves the draft unchanged.

With **Photos** or **Files**, select several items in the picker and confirm to add them together. Tap an image thumbnail in the draft to open a full-screen preview; pinch to zoom, then go back to continue composing. The × removes that attachment.

After confirming a camera photo or picker selection, a pending tile appears in the attachment strip while Wing prepares and saves the files locally. It shows **Adding** and a count for multiple items, then fades into the thumbnail. You can keep typing during photo preparation. If preparation fails, Wing shows an error and keeps your existing draft. Upload starts only when you send.

Sent images show up to five previews in a compact two-column grid. An unpaired image fills the last row. With more than five images, the fifth preview shows **+N** for the remaining images. Tap any preview to open the full-resolution viewer; swipe left or right, or use the arrow icons, to browse every image. Images follow your swipe as neighboring cards, gently receding and settling into place while the controls stay steady. A scrollable thumbnail strip at the bottom lets you jump directly to any image and highlights the current one. Nearby selections slide; distant jumps briefly fade and settle without scrolling through every image. Images have no number labels; the counter shows your position. Pinch to zoom; dragging while zoomed pans the current image. Unavailable previews retry when you return to Wing or the connection recovers, and the retry icon remains available.

A draft can hold up to **40 attachments** and **128 MiB** in total. Generic files are limited to **16 MiB each**. Wing shows an error if a selection is too large and keeps your existing draft; your Hermes server or provider may have a smaller limit.

If Wing cannot prepare a selected photo, it shows the reason and keeps your existing draft. Choose a JPEG, PNG or WebP image within the processing limits and try again.

Photos are cleaned of private metadata before upload. Large discarded metadata,
appended capture information and damaged optional orientation metadata do not
block a photo; unreadable orientation leaves the pixels in their stored position.

## Reference a file on the Hermes server

Type `@` in the composer to choose a server file or folder. Tap a folder row to
browse it; its plus icon adds folder context. The header's folder icon adds the
current folder. Selections stay editable text, including in an outgoing-message
edit. You can also type `@file:/absolute/path` or `@folder:/absolute/path`;
quote paths with spaces. Files support line ranges such as
`@file:/work/notes.md:2-8`.
End a folder query with `/`, such as `@folder:/work/`, to browse its contents.

Wing reads text files when the message dispatches, including after an outbox
delay. Selected locations survive chat-workspace changes. An unavailable file
pauses the entire message for correction. Each text file can be up to 4 MiB;
use at most 16 references and narrow them if they exceed the chat's context limit.
Folder context includes a recursive, ignore-aware bounded listing and sizes or
line counts, rather than every file's contents.

Browsing follows the server's managed file permissions. This first version uses
the host server's POSIX filesystem. Container/SSH workspaces and server-image
vision references are planned separately; phone Photos/Camera still work as above.
When the chat's host workspace is unknown, select an absolute server path.

## Open a result

Tap an assistant file or media result to preview it. Wing supports images, PDFs,
Markdown, diagrams, self-contained HTML and common audio/video formats.
Markdown opens as formatted content with icon-only Raw/formatted, copy, share
and download controls. **Download** lets you choose where Android saves the file;
Wing imposes no fixed download-size limit. Cancelling the destination picker saves
nothing. Older server file links may no longer be available.

[Find messages and outputs](EXECUTION_FIND_AND_OUTPUTS.md) · [File viewer details](OPENING_OUTPUT_FILES.md)
