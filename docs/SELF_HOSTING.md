# Connect a self-hosted Hermes server

Wing uses the **Webapp served by the Hermes gateway**. The standalone Dashboard can show profiles and history but cannot serve Wing’s chat protocol. Use current, unmodified upstream Hermes and confirm your profile can answer on the host. Follow the [official gateway Webapp guide](https://hermes-agent.nousresearch.com/docs/user-guide/desktop#use-the-desktop-workspace-from-a-browser).

## Make the gateway Webapp reachable

Enable `webapp.enabled` in Hermes and configure its address before restarting the gateway. The default Webapp port is **9120**. For a trusted LAN or VPN, `webapp.host: 0.0.0.0` enables remote access with the dashboard sign-in gate. For an HTTPS reverse proxy on the Hermes host, keep the loopback bind and set `webapp.public_url` to the public address. A proxy on a separate machine, such as pfSense, needs a LAN-reachable listener: use `webapp.host: 0.0.0.0` and target the Hermes host’s LAN address and Webapp port. Forward WebSocket traffic as well as HTTP to this gateway listener.

Use the stock username/password provider on a trusted network or VPN, or the supported OAuth sign-in for an internet-facing deployment. Keep model-provider keys on Hermes. Open the Webapp in your phone’s browser and confirm sign-in works. `localhost` on the phone means the phone itself.

An existing standalone Dashboard URL needs to be replaced or its proxy retargeted to this gateway listener. A server update alone does not retarget the address. Review active work before restarting your gateway.

## Add the address in Wing

Choose **Connect your agent → Use an address** and enter the complete gateway Webapp base URL, for example `http://hermes.home:9120` or `https://hermes.example.com/hermes`. Include a custom port or proxy path if your setup uses one. Use the base address, not a private one-use link from `hermes webapp`. Do not add `/api/ws`; Wing finds the live-chat endpoint itself.

Enter the dashboard username and password if your server uses them. **Custom setup** is for deployments that need extra proxy headers, proxy-managed sign-in or a separate chat address. Review a separate chat address carefully: it receives your chat authentication and any configured access headers. Most setups can leave Custom setup alone.

Tap **Check connection**. Wing checks profile access, canonical chat support on the authenticated connection and session history separately. Results update in place on the sign-in screen, without moving the form. When all three pass, tap **Next** or swipe left, name the connection and tap **Save and open**. Send a message to verify your model provider too; a connection check does not run the model.

## Connection help

| What you see | What to check |
| --- | --- |
| Dashboard unreachable | Address, port, VPN, firewall and whether Hermes is still running. Try the dashboard URL in your phone's browser. |
| Sign-in fails | Dashboard credentials and any access proxy. Model-provider keys are different. |
| Chat address needs changing | Open the instance menu → **Edit instance**, enter the gateway Webapp base URL and check the connection again. |
| Profiles load, but live chat fails | Your proxy must forward WebSocket connections to the same Hermes installation. Check its `/api/ws` route. |
| Redirect error | Enter the dashboard's final URL directly. Wing does not forward credentials through redirects. |
| Connected, but no reply | Confirm the selected Hermes profile can answer on the host and its model provider is configured. |

For more detail, see [connection diagnostics](CONNECTION_DIAGNOSTICS_AND_VERSIONS.md). When reporting a problem, include the Wing version, Android version and redacted error; do not share passwords, tokens or private chat content. [Reporting guidance](../SECURITY.md).
