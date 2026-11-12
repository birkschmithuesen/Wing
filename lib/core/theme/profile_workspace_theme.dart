import 'package:flutter/material.dart';
import 'wing_theme.dart';

/// Shared appearance for the workspace, connection setup and app shell.
enum WorkspaceAccent {
  teal('Teal', Color(0xFF65C7BC), Color(0xFF126D70)),
  iris('Iris', Color(0xFFD0BFFF), Color(0xFF6341A7)),
  glacier('Glacier', Color(0xFFABC9FF), Color(0xFF285F9B)),
  coral('Coral', Color(0xFFFFC3AE), Color(0xFF984728)),
  gold('Gold', Color(0xFFF0D589), Color(0xFF745A0A));

  const WorkspaceAccent(this.label, this.dark, this.light);
  final String label;
  final Color dark;
  final Color light;
}

ThemeData profileWorkspaceTheme(
  ThemeData base, {
  WorkspaceAccent accent = WorkspaceAccent.teal,
}) {
  return wingTheme(
    base.brightness,
    accent: base.brightness == Brightness.dark ? accent.dark : accent.light,
  );
}
