# Security and support

Report reproducible client bugs through [Wing's GitHub issues](https://github.com/tarkilhk/Wing/issues).

For a suspected vulnerability, [report it privately](https://github.com/tarkilhk/Wing/security/advisories/new). Do not post exploit details or credentials in public issues. Wing's maintainers can coordinate any server-related findings.

Before sharing logs, screenshots or diagnostics:

- Remove passwords, provider/API keys, Authorization and Cookie values, custom access headers, session tokens and WebSocket tickets.
- Replace private hostnames, addresses, profile/session identifiers and conversation content with synthetic examples.
- Remove personal attachments and output files.
- Exclude `key.properties`, keystores, signing credentials and local environment files.

Include the app version/build, Android version, backend revision if known, expected behavior and minimal reproduction steps. Clearly distinguish an actual server result from a fixture or an assumption.

## Connecting safely

Use HTTPS or an encrypted private network for remote access. Plain HTTP does not encrypt credentials or messages. Keep the dashboard authenticated and restrict who can reach it. The app refuses HTTP redirects for dashboard requests; configure the final address and path directly. Custom access-header secrets are stored with connection credentials in Android secure storage.

Only install artifacts from a source you trust. Wing uses `com.tarkilhk.wing` and its own signing identity. Debug builds and unsigned build outputs are not production releases. Download published builds from [Wing Releases](https://github.com/tarkilhk/Wing/releases).

## Data handling

[PRIVACY.md](PRIVACY.md) describes device storage, server processing, dictation, notifications and deletion. Synthetic credentials in tests are fixtures; real credentials, personal logs and signing material must never be added to the repository.
