import 'package:flutter/material.dart';

import '../models/app_preferences.dart';
import 'profile_workspace_theme.dart';

extension AppThemeRendering on AppThemePreference {
  ThemeMode get themeMode => switch (this) {
    AppThemePreference.system => ThemeMode.system,
    AppThemePreference.light => ThemeMode.light,
    AppThemePreference.dark => ThemeMode.dark,
  };
}

extension AppAccentRendering on AppAccentPreference {
  WorkspaceAccent get appearance => switch (this) {
    AppAccentPreference.teal => WorkspaceAccent.teal,
    AppAccentPreference.iris => WorkspaceAccent.iris,
    AppAccentPreference.glacier => WorkspaceAccent.glacier,
    AppAccentPreference.coral => WorkspaceAccent.coral,
    AppAccentPreference.gold => WorkspaceAccent.gold,
  };
}

extension AppTextSizeRendering on AppTextSizePreference {
  String get label => switch (this) {
    AppTextSizePreference.system => 'System',
    AppTextSizePreference.small => 'Small',
    AppTextSizePreference.standard => 'Default',
    AppTextSizePreference.large => 'Large',
    AppTextSizePreference.extraLarge => 'Extra large',
  };

  String get description => this == AppTextSizePreference.system
      ? 'Use Android accessibility text size exactly.'
      : '${(multiplier * 100).round()}% of the Android text size.';

  TextScaler applyTo(TextScaler system) => this == AppTextSizePreference.system
      ? system
      : _AppTextScaler(system, multiplier);
}

class _AppTextScaler extends TextScaler {
  const _AppTextScaler(this.system, this.multiplier);
  final TextScaler system;
  final double multiplier;
  @override
  double scale(double fontSize) => system.scale(fontSize) * multiplier;
  @override
  double get textScaleFactor => scale(14) / 14;
  @override
  bool operator ==(Object other) =>
      other is _AppTextScaler &&
      other.system == system &&
      other.multiplier == multiplier;
  @override
  int get hashCode => Object.hash(system, multiplier);
}
