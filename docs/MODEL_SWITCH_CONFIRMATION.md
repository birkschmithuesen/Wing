# Chat model confirmation

When a model change needs confirmation, Wing shows Hermes' warning with
**Cancel** and **Switch model**. Read the warning before approving: it may explain
additional model costs or other selection limits. Long warnings scroll while the
actions remain available.

Cancel, Android Back, or tapping outside the dialog keeps the current model,
reasoning setting, and fast mode. Approval changes the model for the selected
chat, then applies the requested additional settings. It does not change the
profile's default model.

While the dialog is open, Wing blocks duplicate model changes and message
submission. If you switch chats or profiles, or the chat's state changes, the
pending approval becomes invalid. Review the current selection before trying
again.

A failed or unconfirmed model change is not automatically retried. Check the
current model before repeating it. If the model changes but another setting
fails, review those settings separately.
