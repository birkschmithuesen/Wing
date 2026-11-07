# MCP connector setup and sign-in

Open **Hermes administration → MCP connectors** for the selected connection and profile.

## Add a connector

Remote services support browser sign-in, bearer tokens, no authentication or custom headers. Programs running on Hermes accept a command, one argument per line and optional environment credentials. Fields explain their format; custom-header values are sent exactly as entered, while bearer-token setup adds the authentication prefix.

Advanced settings support pre-registered OAuth clients, authentication methods, scopes, registered callbacks and certificate/key/CA paths on the server. The form does not upload certificates, install programs, import arbitrary configuration or convert an existing connector's authentication mode.

Creating a connector saves its configuration. **Test connection** connects to the service or starts the configured program. Browser authentication proceeds to sign-in.

The open form keeps its draft, including entered credentials, while you edit. Leaving or changing profiles asks for discard confirmation. Draft credentials are not saved on the phone. If setup is unconfirmed, review the connector list before retrying: some credentials may already have been saved on Hermes.

## Browser sign-in

Start sign-in opens the service's browser authorization page. Wing can receive a supported callback on the phone, or you can paste the full callback URL into the sign-in screen. A received callback is not success until Hermes confirms authorization.

A configured callback remains authoritative. If the phone's callback port is occupied, resolve the displayed error before retrying. Providers can reject callback addresses or client registration. Tokens and renewal are managed by Hermes.

Cancel closes the sign-in flow. If Hermes lacks the required sign-in support, Wing provides update guidance without upgrading the server automatically. Device-code and other unsupported remote sign-in methods provide instructions to complete login on the same server and profile.

After external login, return to **Test connection**. Use **Reconnect MCP tools** below the list to apply configuration and sign-ins to existing chats. Its confirmation explains that it affects all server profiles and may increase token usage on the next message.

## Cached runtime status

Connector rows and details also show Hermes' last runtime observation, including
connection and authentication status. Refresh reads this cache without starting
a connector or testing it. **Sign in again** identifies a reported authentication
problem. Cached status and an explicit test have separate check times and results;
a failed refresh keeps the last known observation labelled as such.

## Connected apps

Hosted app accounts have a separate destination at **Administration → Access and
connectors → Connected apps**, when supported by your Hermes setup. Add a named
account, open its authorization link, then use **Check authorization** to confirm
it. Accounts for the same app can be named, reconnected or removed separately.

A chat may ask you to connect an account. Open its authorization link, return to
**Check connection status**, then choose **Continue**. Opening the browser alone
does not establish access. MCP consent shows the server-supplied command or URL,
working directory and environment variable names for you to review.

## Check the result

A connector starts untested, shows progress while testing, then reports Connected or Connection failed. Expand **Available tools** for returned names and descriptions, or **Failure details** for the reported reason. A fresh test replaces the previous result.

A connection check establishes access at that time, rather than proving that every tool action will succeed. Per-tool configuration changes are unavailable. See [Administration](ADMINISTRATION.md) for related profile settings and health checks.
