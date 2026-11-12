import 'package:flutter/material.dart';

/// A measured setting, independent of asynchronous loading feedback.
class StudioCapacityMeter extends StatelessWidget {
  const StudioCapacityMeter({
    super.key,
    required this.fraction,
    required this.label,
  });
  final double fraction;
  final String label;
  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    value: '${(fraction.clamp(0, 1) * 100).round()}%',
    child: SizedBox(
      height: 4,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: FractionallySizedBox(
            widthFactor: fraction.clamp(0, 1),
            heightFactor: 1,
            child: ColoredBox(color: Theme.of(context).colorScheme.primary),
          ),
        ),
      ),
    ),
  );
}
