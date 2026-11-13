import 'studio_error.dart';
import 'gateway_approval_panel.dart';
import 'studio_form_actions.dart';
import 'package:flutter/material.dart';

import '../models/gateway_approval.dart';

/// One review surface; a failed send leaves the decision explicit and retryable.
class NotificationApprovalReview extends StatefulWidget {
  const NotificationApprovalReview({
    super.key,
    required this.request,
    required this.choice,
    required this.changes,
    required this.offline,
    required this.pending,
    required this.submit,
  });
  final GatewayApprovalRequest request;
  final String choice;
  final Listenable changes;
  final bool Function() offline;
  final bool Function() pending;
  final Future<void> Function() submit;

  @override
  State<NotificationApprovalReview> createState() => _ReviewState();
}

class _ReviewState extends State<NotificationApprovalReview> {
  bool sending = false;
  String? error;

  Future<void> send() async {
    setState(() {
      sending = true;
      error = null;
    });
    try {
      await widget.submit();
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          sending = false;
          error = 'Decision not confirmed. Check the connection, then retry.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.changes,
    builder: (context, _) {
      final offline = widget.offline();
      final pending = widget.pending();
      final status = !pending
          ? 'This approval is no longer pending.'
          : sending
          ? null
          : error ??
                (offline
                    ? 'Offline—approval not sent. Reconnect to retry.'
                    : null);
      final scope = switch (widget.choice) {
        'always' =>
          'Permanently allow matching commands, including in future chats.',
        'session' => 'Allow matching commands for this session.',
        'deny' => 'Reject this request. The command will not run.',
        _ => 'Allow this request once.',
      };
      return PopScope(
        canPop: !sending,
        child: StudioDialog(
          titleTextStyle: Theme.of(context).textTheme.titleLarge,
          title: Text(
            widget.choice == 'always' ? 'Always allow?' : 'Review command',
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(scope, style: Theme.of(context).textTheme.titleSmall),
                if (status != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: StudioError(status, icon: Icons.rule_outlined),
                  ),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: ApprovalCommandDetails(request: widget.request),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            StudioFormActions(
              onCancel: sending ? null : () => Navigator.pop(context),
              cancelLabel: pending ? 'Cancel approval decision' : 'Close',
              onConfirm: sending || offline || !pending ? null : send,
              confirmLabel: switch (widget.choice) {
                'always' => 'Always allow',
                'session' => 'Allow for session',
                'deny' => 'Deny request',
                _ => 'Allow once',
              },
              confirmIcon: widget.choice == 'deny'
                  ? Icons.block
                  : Icons.verified_user_outlined,
              busy: sending,
              progressLabel: 'Sending approval decision',
            ),
          ],
        ),
      );
    },
  );
}
