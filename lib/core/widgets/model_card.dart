import 'selection_viewport.dart';
import 'package:flutter/material.dart';
import '../models/model_choice.dart';
import '../models/model_catalog_details.dart';
import '../presentation/chat_model_labels.dart';
import '../theme/wing_theme.dart';

Future<void> showModelCard(BuildContext context, ModelChoice choice) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => ModelCard(choice: choice),
    );

/// Renders supplied facts only; it never infers a capability from a model name.
class ModelCard extends StatelessWidget {
  const ModelCard({required this.choice, super.key});
  final ModelChoice choice;

  @override
  Widget build(BuildContext context) {
    final tokens = WingTokens.of(context);
    final prices = choice.prices;
    final controls = choice.controls;
    final provider = choice.providerInfo;
    final usage = provider?.usage;
    final plan = provider?.planUsage;
    Widget fact(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: tokens.typography.label.copyWith(color: tokens.muted),
            ),
          ),
          const SizedBox(width: 16),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: tokens.typography.body,
            ),
          ),
        ],
      ),
    );
    Widget window(AccountUsageWindow window) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        fact(
          window.label,
          '${window.usedPercent.toStringAsFixed(window.usedPercent % 1 == 0 ? 0 : 1)}% used',
        ),
        if (window.resetsAt != null)
          fact('Resets', _resetLabel(context, window.resetsAt!)),
      ],
    );
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .8,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      catalogModelLabel(choice.label),
                      style: tokens.typography.title,
                    ),
                  ),
                  StudioButtonPress(
                    child: IconButton(
                      tooltip: 'Close model card',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ),
                ],
              ),
              Text(
                choice.routeLabel,
                style: tokens.typography.label.copyWith(color: tokens.muted),
              ),
              viewportSelection(
                SelectableText(
                  choice.model,
                  style: tokens.typography.mono.copyWith(color: tokens.muted),
                ),
              ),
              if (provider?.warning != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    provider!.warning!,
                    style: tokens.typography.label.copyWith(
                      color: tokens.warning,
                    ),
                  ),
                ),
              if (prices != null &&
                  (prices.free ||
                      prices.input != null ||
                      prices.output != null ||
                      prices.cache != null)) ...[
                const Divider(height: 24),
                if (prices.apiEquivalent || !prices.free)
                  Text(
                    prices.units.toUpperCase(),
                    style: tokens.typography.label.copyWith(
                      color: tokens.muted,
                    ),
                  ),
                if (prices.free)
                  fact('Price', 'Free')
                else ...[
                  if (prices.input != null) fact('Input', prices.input!),
                  if (prices.output != null) fact('Output', prices.output!),
                  if (prices.cache != null) fact('Cached input', prices.cache!),
                ],
              ],
              if (controls != null &&
                  (controls.reasoning || controls.fast)) ...[
                const Divider(height: 24),
                if (controls.reasoning) fact('Reasoning', 'Adjustable'),
                if (controls.fast) fact('Fast mode', 'Available'),
              ],
              if (plan != null) ...[
                const Divider(height: 24),
                if (plan.plan case final name? when name.isNotEmpty)
                  fact('Plan', name),
                if (choice.allowanceLabel case final label?)
                  fact('Allowance', label),
                for (final gauge in choice.allowanceGauges) ...[
                  fact(gauge.label, gauge.remainingLabel),
                  if (gauge.resetsAt case final reset?)
                    fact('Resets', _resetLabel(context, reset)),
                ],
                if (plan.pauseLabel case final reason?)
                  Text(
                    reason,
                    style: tokens.typography.label.copyWith(
                      color: tokens.warning,
                    ),
                  ),
                if (plan.creditsPay case final enabled?
                    when !choice.allowanceExempt)
                  fact(
                    'After allowance',
                    enabled ? 'Uses credits' : 'Stops at the limit',
                  ),
              ],
              if (usage != null &&
                  plan == null &&
                  (usage.windows.isNotEmpty || usage.accounts.isNotEmpty)) ...[
                const Divider(height: 24),
                Text(
                  'ACCOUNT USAGE',
                  style: tokens.typography.label.copyWith(color: tokens.muted),
                ),
                for (final w in usage.windows) window(w),
                for (final account in usage.accounts) ...[
                  fact(
                    account.label.isEmpty ? 'Account' : account.label,
                    account.state.name,
                  ),
                  for (final w in account.windows) window(w),
                  if (account.state == AccountUsageState.limited &&
                      account.resetsAt != null)
                    fact(
                      'Account resets',
                      _resetLabel(context, account.resetsAt!),
                    ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _resetLabel(BuildContext context, DateTime value) {
    final local = value.toLocal();
    final material = MaterialLocalizations.of(context);
    return '${material.formatShortDate(local)} · ${material.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
  }
}
