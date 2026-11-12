import 'package:flutter/material.dart';
import 'wing_theme.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

// flutter_markdown merges its theme paragraph style into nested quotes. Flutter
// typography defaults to inherit:false, which would discard quote formatting.
ThemeData profileMarkdownTheme(ThemeData theme) => theme.copyWith(
  scrollbarTheme: theme.scrollbarTheme.copyWith(
    thickness: const WidgetStatePropertyAll(3),
    radius: const Radius.circular(999),
    thumbColor: WidgetStatePropertyAll(
      theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.35),
    ),
    trackVisibility: const WidgetStatePropertyAll(false),
    crossAxisMargin: 3,
  ),
  typography: theme.typography.copyWith(
    englishLike: _inheritingProse(theme.typography.englishLike),
    dense: _inheritingProse(theme.typography.dense),
    tall: _inheritingProse(theme.typography.tall),
  ),
  textTheme: theme.textTheme.copyWith(
    bodyMedium: theme.textTheme.bodyMedium!.copyWith(inherit: true),
  ),
);

TextTheme _inheritingProse(TextTheme text) =>
    text.copyWith(bodyMedium: text.bodyMedium!.copyWith(inherit: true));

/// Desktop-like document styling, without the Markdown package's fixed blue
/// quote fill. Shared by conversation prose and inline questions.
MarkdownStyleSheet profileMarkdownStyle(
  ThemeData theme, {
  bool compact = false,
}) {
  final colors = theme.colorScheme;
  final body = compact
      ? theme.textTheme.bodyMedium!.copyWith(fontSize: 14)
      : theme.textTheme.bodyLarge!;
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: body.copyWith(inherit: true, height: compact ? 1.4 : 1.5),
    blockSpacing: 8,
    a: TextStyle(color: colors.primary, decoration: TextDecoration.underline),
    blockquote: TextStyle(
      // The renderer merges paragraph color over blockquote color. An explicit
      // foreground keeps quote text muted through that merge, including bold.
      foreground: Paint()..color = colors.onSurfaceVariant,
      fontStyle: FontStyle.italic,
    ),
    blockquotePadding: const EdgeInsets.fromLTRB(12, 2, 0, 2),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: colors.outlineVariant, width: 3)),
    ),
    code: theme.textTheme.bodyMedium?.copyWith(
      fontFamily: 'monospace',
      color: colors.onSurface,
      backgroundColor: colors.surfaceContainerHigh,
    ),
    codeblockDecoration: BoxDecoration(
      color: colors.surfaceContainerLow,
      borderRadius: WingRadius.card,
    ),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: colors.outlineVariant)),
    ),
  );
}
