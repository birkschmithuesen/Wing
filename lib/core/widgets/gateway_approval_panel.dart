import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../models/gateway_approval.dart';
import '../theme/wing_theme.dart';
import 'selection_viewport.dart';
import 'studio_error.dart';

/// Exact command review shared by chat, bot, group and notification approvals.
/// Completed request receipts belong to Activity; live review stays visible.
class ApprovalCommandDetails extends StatelessWidget {
  const ApprovalCommandDetails({super.key, required this.request});

  final GatewayApprovalRequest request;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      viewportSelection(SelectableText(request.command)),
      if (request.description.isNotEmpty)
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Hermes request details'),
          children: [Text(request.description)],
        ),
    ],
  );
}

/// Live decisions retain their exact server-owned scopes and shared reviewer.
class GatewayApprovalPanel extends StatelessWidget {
  const GatewayApprovalPanel({
    super.key,
    required this.request,
    required this.onRespond,
    this.position = 1,
    this.total = 1,
    this.enabled = true,
    this.error,
  });

  final GatewayApprovalRequest request;
  final ValueChanged<GatewayApprovalChoice> onRespond;
  final int position;
  final int total;
  final bool enabled;
  final String? error;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final preferred =
          (MediaQuery.sizeOf(context).height -
              MediaQuery.viewInsetsOf(context).bottom) *
          .35;
      final footerWidth = request.choices.length * 56.0 + (total > 1 ? 56 : 0);
      final footerRows = math.max(
        1,
        (footerWidth / constraints.maxWidth).ceil(),
      );
      final detailsHeight = constraints.hasBoundedHeight
          ? math.min(
              preferred,
              math.max(0.0, constraints.maxHeight - footerRows * 48),
            )
          : preferred;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: detailsHeight),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      'Review command',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (error case final message?)
                    StudioError(
                      message,
                      icon: Icons.rule_outlined,
                      framed: false,
                    ),
                  ApprovalCommandDetails(request: request),
                ],
              ),
            ),
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (total > 1) Text('$position/$total'),
              for (final choice in request.choices.reversed)
                StudioButtonPress(
                  child: choice == GatewayApprovalChoice.deny
                      ? IconButton.outlined(
                          tooltip: 'Reject',
                          onPressed: enabled ? () => onRespond(choice) : null,
                          icon: const Icon(Icons.close),
                        )
                      : IconButton.filled(
                          tooltip: switch (choice) {
                            GatewayApprovalChoice.once => 'Approve once',
                            GatewayApprovalChoice.session =>
                              'Approve for session',
                            GatewayApprovalChoice.always => 'Always approve',
                            GatewayApprovalChoice.deny => 'Reject',
                          },
                          onPressed: enabled ? () => onRespond(choice) : null,
                          icon: Icon(switch (choice) {
                            GatewayApprovalChoice.once => Icons.check,
                            GatewayApprovalChoice.session =>
                              Icons.playlist_add_check,
                            GatewayApprovalChoice.always => Icons.done_all,
                            GatewayApprovalChoice.deny => Icons.close,
                          }),
                        ),
                ),
            ],
          ),
        ],
      );
    },
  );
}
