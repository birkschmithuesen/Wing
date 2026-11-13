# Configuration backups

Open App settings and choose Backup configuration to export saved connections
and supported device settings, including appearance, composer actions,
notifications, voice choices and connection visibility.

Exports contain credentials. Protect the file as a secret. A confirmed passphrase
of at least eight characters encrypts it; leaving both passphrase fields empty
explicitly creates a plaintext export.

Profile settings, chat drafts and cached transcripts are not included.
Conversations remain on Hermes, and cloud sign-in is performed again after restore.

## Export

Confirm the export, then choose a receiving app in Android's share sheet.
If another share is still open, finish it and try again. Dismissing the chooser
does not delete copies already saved by a receiving app. See
[sharing from Wing](SHARING_AND_CAPTURE.md#sharing-from-wing).

## Restore

Choose a backup created by the current Wing version and enter its passphrase
if encrypted. Older formats need to be exported again with the current app.
Files are limited to 2 MiB and 256 saved connections.

Merge adds or updates imported connections while retaining others. Replace
removes connections absent from the backup. Only settings saved in the file
are restored; unknown or invalid settings are skipped and counted in the result.

Review the result before retrying. A settings failure after connections have
been restored does not undo those confirmed connection changes. Wing reports
whether previous settings were restored or could not be verified or restored.
