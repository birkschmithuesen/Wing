# Get started with Wing

Wing brings your Hermes Agent to Android. You need Android 10 or newer and a Hermes setup with a gateway-served Webapp and working model provider. Wing connects to your agent; it does not run a model on your phone.

## 1. Install Wing

Download the signed APK from the [latest Wing release](https://github.com/tarkilhk/Wing/releases/latest). The **arm64-v8a** APK fits most current phones. Android may ask you to allow installation from the browser or file manager you used to download it.

## 2. Connect your agent

Open Wing and tap **Connect your agent**. Choose the route that matches your setup:

- **Hermes Cloud:** sign in through Nous Portal, choose your organization if asked, and select your instance.
- **Use an address:** enter your Hermes gateway Webapp address and sign-in details. A home or remote server must be reachable from your phone. See [Connecting a self-hosted Hermes server](SELF_HOSTING.md) for host and proxy setup.

Use **Next** or swipe left/right between the setup cards. **Check connection** checks profile access, live chat and history in a fixed results area. Fields and buttons stay in place while the check runs. After a successful check, select **Next** to name the instance, then **Save and open**. You can correct a failed check without replacing a saved connection.

## 3. Start a conversation

Choose a profile, create a chat and send a short message. Reopen the chat to see its saved history. From there, try [chat controls, files, voice and more](FEATURES.md).

For live voice conversations and email draft cards, [set up the optional Wing
plugin](WING_PLUGIN.md) in the profiles where you want those features. It is a
separate server installation; the Android update alone does not enable it.

If a saved profile is unavailable, Chats offers the available profiles directly.
On a short screen or with enlarged text, scroll below the filters to reach these
choices, then choose a profile to reopen the workspace.

If something does not connect, the check screen shows which part needs attention. [Connection help](SELF_HOSTING.md#connection-help) covers the usual fixes. [Good to know](KNOWN_LIMITATIONS.md) explains offline reading and notifications.
