import 'selection_viewport.dart';
import 'studio_form_actions.dart';
import 'studio_error.dart';

import 'package:flutter/material.dart';
import '../theme/wing_theme.dart';

import '../models/gateway_sensitive_prompt.dart';

typedef SensitivePromptResponder = Future<void> Function(String value);

class GatewaySensitivePromptPanel extends StatefulWidget {
  final GatewaySensitivePromptRequest request;
  final SensitivePromptResponder onRespond;
  final bool enabled;

  const GatewaySensitivePromptPanel({
    required this.request,
    required this.onRespond,
    this.enabled = true,
    super.key,
  });

  @override
  State<GatewaySensitivePromptPanel> createState() =>
      _GatewaySensitivePromptPanelState();
}

class _GatewaySensitivePromptPanelState
    extends State<GatewaySensitivePromptPanel> {
  final TextEditingController _controller = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _submitting = false;
  String? _error;

  bool get _enabled => widget.enabled && !_submitting;

  @override
  void didUpdateWidget(GatewaySensitivePromptPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.request.kind != widget.request.kind ||
        oldWidget.request.requestId != widget.request.requestId) {
      _controller.clear();
      _passwordController.clear();
      _submitting = false;
      _error = null;
    }
  }

  @override
  void dispose() {
    _controller.clear();
    _passwordController.clear();
    _controller.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _respond(String value) async {
    if (!_enabled) return;
    final kind = widget.request.kind;
    final requestId = widget.request.requestId;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.onRespond(value);
      if (mounted &&
          widget.request.kind == kind &&
          widget.request.requestId == requestId) {
        _controller.clear();
        _passwordController.clear();
      }
    } catch (_) {
      if (!mounted ||
          widget.request.kind != kind ||
          widget.request.requestId != requestId) {
        return;
      }
      setState(() {
        _controller.clear();
        _passwordController.clear();
        _submitting = false;
        _error = 'Hermes could not accept the response. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final request = widget.request;
    final savesLogin =
        request.kind == GatewaySensitivePromptKind.vaultSaveLogin;
    final showsCode = request.kind == GatewaySensitivePromptKind.vaultCode;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: WingRadius.card,
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.key_rounded,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  request.title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(request.description),
          const SizedBox(height: 12),
          viewportSelection(
            TextField(
              key: const Key('sensitive-prompt-field'),
              controller: _controller,
              enabled: _enabled,
              obscureText: !showsCode && !savesLogin,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: switch (request.kind) {
                GatewaySensitivePromptKind.vaultSaveLogin => const [
                  AutofillHints.username,
                ],
                GatewaySensitivePromptKind.vaultCode => const [
                  AutofillHints.oneTimeCode,
                ],
                _ => const [AutofillHints.password],
              },
              keyboardType: showsCode ? TextInputType.number : null,
              textInputAction: savesLogin
                  ? TextInputAction.next
                  : TextInputAction.done,
              decoration: InputDecoration(
                isDense: true,
                border: OutlineInputBorder(borderRadius: WingRadius.control),
                labelText: request.fieldLabel,
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (value) {
                if (!savesLogin &&
                    widget.request.canRespond(
                      value: _controller.text,
                      password: _passwordController.text,
                    )) {
                  _respond(
                    widget.request.responseValue(
                      value: _controller.text,
                      password: _passwordController.text,
                    ),
                  );
                }
              },
            ),
          ),
          if (savesLogin) ...[
            const SizedBox(height: 12),
            viewportSelection(
              TextField(
                key: const Key('sensitive-prompt-password'),
                controller: _passwordController,
                enabled: _enabled,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: const [AutofillHints.password],
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: WingRadius.control),
                  labelText: 'Password',
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
                onSubmitted: (_) {
                  if (widget.request.canRespond(
                    value: _controller.text,
                    password: _passwordController.text,
                  )) {
                    _respond(
                      widget.request.responseValue(
                        value: _controller.text,
                        password: _passwordController.text,
                      ),
                    );
                  }
                },
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            StudioError(_error!, key: const Key('sensitive-prompt-error')),
          ],
          const SizedBox(height: 12),
          ListenableBuilder(
            listenable: Listenable.merge([_controller, _passwordController]),
            builder: (context, _) => StudioFormActions(
              cancelKey: const Key('sensitive-prompt-cancel'),
              confirmKey: const Key('sensitive-prompt-submit'),
              onCancel: _enabled ? () => _respond('') : null,
              cancelLabel: switch (request.kind) {
                GatewaySensitivePromptKind.vaultUnlock => 'Keep locked',
                GatewaySensitivePromptKind.vaultSaveLogin => "Don't save login",
                GatewaySensitivePromptKind.vaultCode => 'Skip code',
                _ => 'Cancel',
              },
              onConfirm:
                  _enabled &&
                      widget.request.canRespond(
                        value: _controller.text,
                        password: _passwordController.text,
                      )
                  ? () => _respond(
                      widget.request.responseValue(
                        value: _controller.text,
                        password: _passwordController.text,
                      ),
                    )
                  : null,
              confirmLabel:
                  request.kind == GatewaySensitivePromptKind.vaultSaveLogin
                  ? 'Save login'
                  : 'Continue sign-in',
              confirmIcon:
                  request.kind == GatewaySensitivePromptKind.vaultSaveLogin
                  ? Icons.save_outlined
                  : Icons.lock_open_outlined,
              busy: _submitting,
              progressLabel: 'Sending secure response',
            ),
          ),
        ],
      ),
    );
  }
}
