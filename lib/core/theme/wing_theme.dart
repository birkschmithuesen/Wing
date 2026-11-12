/// The Wing app design system.
///
/// One typed token layer that every screen consumes, so spacing, radius,
/// motion, semantic status colors, and the typography ramp are decided once
/// instead of per screen. See `internal/docs/DESIGN_SYSTEM.md` for the Studio charter.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The 4dp spacing grid shared by every Wing surface.
abstract final class WingSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
}

/// Corner radii, growing from small controls to full sheets.
abstract final class WingRadius {
  static const double sm = 6;
  static const double md = 8;
  static const double xl = 12;

  static const BorderRadius control = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius card = BorderRadius.all(Radius.circular(md));
  static const BorderRadius sheet = BorderRadius.vertical(
    top: Radius.circular(xl),
  );
}

/// Motion budget. Animations exist to explain a change, never to decorate.
abstract final class WingMotion {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration standard = Duration(milliseconds: 200);
  static const Duration buttonPress = Duration(milliseconds: 120);
  static const Duration buttonRelease = Duration(milliseconds: 160);
  static const double buttonPressedScale = .97;

  static const Curve curve = Curves.easeOutCubic;
}

/// The Wing typography ramp.
///
/// [mono] owns code, file paths, and terminal output; everything else is prose.
class WingTypography {
  static const String sans = 'Roboto';

  final TextStyle display;
  final TextStyle title;
  final TextStyle section;
  final TextStyle body;
  final TextStyle label;
  final TextStyle mono;

  const WingTypography({
    required this.display,
    required this.title,
    required this.section,
    required this.body,
    required this.label,
    required this.mono,
  });

  static WingTypography ramp(Brightness brightness) {
    return const WingTypography(
      display: TextStyle(
        fontFamily: sans,
        fontSize: 28,
        height: 1.2,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.4,
      ),
      title: TextStyle(
        fontFamily: sans,
        fontSize: 24,
        height: 1.25,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
      section: TextStyle(
        fontFamily: sans,
        fontSize: 16,
        height: 1.3,
        fontWeight: FontWeight.w600,
      ),
      body: TextStyle(fontFamily: sans, fontSize: 16, height: 1.45),
      label: TextStyle(
        fontFamily: sans,
        fontSize: 12,
        height: 1.3,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.2,
      ),
      mono: TextStyle(
        fontSize: 13,
        height: 1.4,
        fontFamily: 'monospace',
        fontFamilyFallback: ['monospace'],
      ),
    );
  }

  TextTheme applyTo(TextTheme base, Color onSurface, Color muted) {
    return base.copyWith(
      headlineSmall: display.copyWith(color: onSurface),
      titleLarge: title.copyWith(color: onSurface),
      titleMedium: section.copyWith(color: onSurface),
      bodyMedium: body.copyWith(color: onSurface),
      bodySmall: label.copyWith(color: muted),
      labelMedium: label.copyWith(color: muted),
      labelSmall: label.copyWith(color: muted),
    );
  }
}

/// The Wing design tokens, carried on [ThemeData.extensions].
@immutable
class WingTokens extends ThemeExtension<WingTokens> {
  /// Studio source palette. Grammar colors never replace diagnostic/diff colors.
  Color? sourceColor(String? scope) {
    final dark = brightness == Brightness.dark;
    return switch (scope?.split('.').first) {
      'keyword' ||
      'selector-tag' ||
      'meta' => dark ? const Color(0xFFD3ACF5) : const Color(0xFF7040A0),
      'string' || 'regexp' || 'attribute' || 'selector-attr' =>
        dark ? const Color(0xFFA6D8A8) : const Color(0xFF316B36),
      'number' ||
      'literal' ||
      'symbol' ||
      'bullet' => dark ? const Color(0xFFF0BD87) : const Color(0xFF8A4A13),
      'title' || 'built_in' || 'type' || 'name' || 'selector-class' =>
        dark ? const Color(0xFF91C9F5) : const Color(0xFF285E91),
      'variable' ||
      'attr' ||
      'params' => dark ? const Color(0xFF7DD4C8) : const Color(0xFF226A60),
      'comment' || 'doctag' || 'wing-line-number' => muted,
      _ => null,
    };
  }

  final Brightness brightness;
  final Color surface;
  final Color raised;
  final Color border;
  final Color onSurface;
  final Color muted;
  final Color accent;
  final Color success;
  final Color warning;
  final Color danger;
  final Color running;
  final Color blocked;
  final WingTypography typography;

  /// Studio error-family fills, derived from the approved OKLCH palette.
  Color get warningSurface => brightness == Brightness.dark
      ? const Color(0xFF2F281B)
      : const Color(0xFFFDF4E3);

  Color get dangerSurface => brightness == Brightness.dark
      ? const Color(0xFF352422)
      : const Color(0xFFFFF1EF);

  /// Shared unread treatment for Recents identity cards and cached viewports.
  Color recentUnreadTint(Color primaryContainer) =>
      (brightness == Brightness.dark ? accent : primaryContainer).withValues(
        alpha: brightness == Brightness.dark ? .14 : .17,
      );

  Color get recentUnreadBorder =>
      Color.lerp(border, accent, brightness == Brightness.dark ? .35 : .17)!;

  const WingTokens({
    required this.brightness,
    required this.surface,
    required this.raised,
    required this.border,
    required this.onSurface,
    required this.muted,
    required this.accent,
    required this.success,
    required this.warning,
    required this.danger,
    required this.running,
    required this.blocked,
    required this.typography,
  });

  factory WingTokens.dark() {
    return WingTokens(
      brightness: Brightness.dark,
      surface: const Color(0xFF101B24),
      raised: const Color(0xFF192934),
      border: const Color(0xFF344C58),
      onSurface: const Color(0xFFEBF1F2),
      muted: const Color(0xFFADBDC4),
      accent: const Color(0xFF65C7BC),
      success: const Color(0xFF4ADE80),
      warning: const Color(0xFFFBBF24),
      danger: const Color(0xFFF87171),
      running: const Color(0xFF60A5FA),
      blocked: const Color(0xFFF59E0B),
      typography: WingTypography.ramp(Brightness.dark),
    );
  }

  factory WingTokens.light() {
    return WingTokens(
      brightness: Brightness.light,
      surface: const Color(0xFFF7F7F4),
      raised: const Color(0xFFFFFFFF),
      border: const Color(0xFFD6E0E1),
      onSurface: const Color(0xFF1B2D36),
      muted: const Color(0xFF586970),
      accent: const Color(0xFF126D70),
      success: const Color(0xFF15803D),
      warning: const Color(0xFFB45309),
      danger: const Color(0xFFB91C1C),
      running: const Color(0xFF1D4ED8),
      blocked: const Color(0xFF9A5B00),
      typography: WingTypography.ramp(Brightness.light),
    );
  }

  static WingTokens forBrightness(Brightness brightness) {
    return brightness == Brightness.dark
        ? WingTokens.dark()
        : WingTokens.light();
  }

  /// The tokens for the closest theme, falling back to a matching set when a
  /// widget is mounted under a plain [ThemeData] (tests, previews, plugins).
  static WingTokens of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<WingTokens>() ??
        WingTokens.forBrightness(theme.brightness);
  }

  @override
  WingTokens copyWith({
    Brightness? brightness,
    Color? surface,
    Color? raised,
    Color? border,
    Color? onSurface,
    Color? muted,
    Color? accent,
    Color? success,
    Color? warning,
    Color? danger,
    Color? running,
    Color? blocked,
    WingTypography? typography,
  }) {
    return WingTokens(
      brightness: brightness ?? this.brightness,
      surface: surface ?? this.surface,
      raised: raised ?? this.raised,
      border: border ?? this.border,
      onSurface: onSurface ?? this.onSurface,
      muted: muted ?? this.muted,
      accent: accent ?? this.accent,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      running: running ?? this.running,
      blocked: blocked ?? this.blocked,
      typography: typography ?? this.typography,
    );
  }

  @override
  WingTokens lerp(ThemeExtension<WingTokens>? other, double t) {
    if (other is! WingTokens) return this;
    return WingTokens(
      brightness: t < 0.5 ? brightness : other.brightness,
      surface: Color.lerp(surface, other.surface, t)!,
      raised: Color.lerp(raised, other.raised, t)!,
      border: Color.lerp(border, other.border, t)!,
      onSurface: Color.lerp(onSurface, other.onSurface, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      running: Color.lerp(running, other.running, t)!,
      blocked: Color.lerp(blocked, other.blocked, t)!,
      typography: t < 0.5 ? typography : other.typography,
    );
  }
}

/// Builds the Wing [ThemeData] for one brightness, tokens attached.
ThemeData wingTheme(Brightness brightness, {Color? accent}) {
  final tokens = WingTokens.forBrightness(brightness).copyWith(accent: accent);
  final dark = brightness == Brightness.dark;
  final onAccent = dark ? const Color(0xFF102C32) : Colors.white;
  final selected =
      accent == null || accent == WingTokens.forBrightness(brightness).accent
      ? dark
            ? const Color(0xFF20454A)
            : const Color(0xFFE2F1EE)
      : Color.alphaBlend(tokens.accent.withValues(alpha: .12), tokens.raised);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: tokens.accent,
        brightness: brightness,
      ).copyWith(
        surface: tokens.surface,
        surfaceContainerLowest: tokens.raised,
        surfaceContainerLow: tokens.raised,
        surfaceContainer: tokens.raised,
        surfaceContainerHigh: tokens.raised,
        surfaceContainerHighest: selected,
        onSurface: tokens.onSurface,
        onSurfaceVariant: tokens.muted,
        primary: tokens.accent,
        onPrimary: onAccent,
        primaryContainer: selected,
        onPrimaryContainer: tokens.onSurface,
        secondary: tokens.accent,
        onSecondary: onAccent,
        secondaryContainer: selected,
        onSecondaryContainer: tokens.onSurface,
        error: tokens.danger,
        outline: tokens.muted,
        outlineVariant: tokens.border,
      );

  final base = ThemeData(
    colorScheme: scheme,
    fontFamily: WingTypography.sans,
    brightness: brightness,
    useMaterial3: true,
  );

  const actionShape = RoundedRectangleBorder(borderRadius: WingRadius.control);
  final panelShape = RoundedRectangleBorder(
    borderRadius: WingRadius.card,
    side: BorderSide(color: tokens.border),
  );
  final focusBorder = WidgetStateProperty.resolveWith<BorderSide?>(
    (states) => states.contains(WidgetState.focused)
        ? BorderSide(color: tokens.accent, width: 2)
        : null,
  );
  final action = TextButton.styleFrom(
    minimumSize: const Size(48, 40),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    shape: actionShape,
    tapTargetSize: MaterialTapTargetSize.padded,
    textStyle: const TextStyle(
      fontFamily: WingTypography.sans,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    ),
  ).copyWith(backgroundBuilder: _studioButtonLayer);
  final fieldBorder = OutlineInputBorder(
    borderRadius: WingRadius.control,
    borderSide: BorderSide(color: tokens.border),
  );

  return base.copyWith(
    scaffoldBackgroundColor: tokens.surface,
    canvasColor: tokens.raised,
    disabledColor: tokens.muted,
    focusColor: tokens.accent.withValues(alpha: .18),
    textTheme: tokens.typography.applyTo(
      base.textTheme,
      tokens.onSurface,
      tokens.muted,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: tokens.surface,
      foregroundColor: tokens.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      systemOverlayStyle:
          (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
              .copyWith(
                statusBarColor: Colors.transparent,
                systemNavigationBarColor: tokens.surface,
                systemNavigationBarDividerColor: tokens.surface,
              ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: action.copyWith(
        side: focusBorder,
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? tokens.muted
              : states.contains(WidgetState.focused)
              ? tokens.accent
              : null,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? tokens.border
              : states.contains(WidgetState.focused)
              ? tokens.raised
              : null,
        ),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: action.copyWith(
        elevation: const WidgetStatePropertyAll(0),
        side: focusBorder,
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? tokens.muted
              : states.contains(WidgetState.focused)
              ? tokens.accent
              : onAccent,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? tokens.border
              : states.contains(WidgetState.focused)
              ? tokens.raised
              : tokens.accent,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: action.copyWith(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? tokens.muted
              : tokens.accent,
        ),
        side: WidgetStateProperty.resolveWith(
          (states) => BorderSide(
            color: states.contains(WidgetState.focused)
                ? tokens.accent
                : tokens.border,
            width: states.contains(WidgetState.focused) ? 2 : 1,
          ),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: action.copyWith(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? tokens.muted
              : tokens.accent,
        ),
        side: focusBorder,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: actionShape,
        disabledForegroundColor: tokens.muted,
      ).copyWith(side: focusBorder, backgroundBuilder: _studioButtonLayer),
    ),
    menuButtonTheme: const MenuButtonThemeData(
      style: ButtonStyle(backgroundBuilder: _studioButtonLayer),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: tokens.raised,
      border: fieldBorder,
      enabledBorder: fieldBorder,
      disabledBorder: fieldBorder,
      focusedBorder: fieldBorder.copyWith(
        borderSide: BorderSide(color: tokens.accent, width: 2),
      ),
      errorBorder: fieldBorder.copyWith(
        borderSide: BorderSide(color: tokens.danger),
      ),
      focusedErrorBorder: fieldBorder.copyWith(
        borderSide: BorderSide(color: tokens.danger, width: 2),
      ),
      labelStyle: TextStyle(
        fontFamily: WingTypography.sans,
        color: tokens.muted,
      ),
      errorStyle: tokens.typography.label.copyWith(
        color: tokens.onSurface,
        fontWeight: FontWeight.w400,
        letterSpacing: 0,
      ),
      errorMaxLines: 4,
      hintStyle: TextStyle(
        fontFamily: WingTypography.sans,
        color: tokens.muted,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    ),
    chipTheme: ChipThemeData(
      shape: actionShape,
      side: BorderSide(color: tokens.border),
      backgroundColor: tokens.raised,
      selectedColor: selected,
      disabledColor: tokens.border,
      showCheckmark: false,
      labelStyle: TextStyle(
        fontFamily: WingTypography.sans,
        color: tokens.onSurface,
        fontSize: 13,
      ),
      secondaryLabelStyle: TextStyle(
        fontFamily: WingTypography.sans,
        color: tokens.onSurface,
        fontSize: 13,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      selectedIcon: const SizedBox.shrink(),
      style: action.copyWith(
        foregroundColor: WidgetStatePropertyAll(tokens.onSurface),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? selected : tokens.raised,
        ),
        side: WidgetStatePropertyAll(BorderSide(color: tokens.border)),
      ),
    ),
    listTileTheme: ListTileThemeData(
      titleTextStyle: TextStyle(
        fontFamily: WingTypography.sans,
        fontSize: 16,
        color: tokens.onSurface,
      ),
      subtitleTextStyle: TextStyle(
        fontFamily: WingTypography.sans,
        fontSize: 13,
        color: tokens.muted,
      ),
      iconColor: tokens.muted,
      textColor: tokens.onSurface,
      selectedColor: tokens.accent,
      selectedTileColor: selected,
      shape: actionShape,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: tokens.accent,
      unselectedLabelColor: tokens.muted,
      indicator: BoxDecoration(
        color: selected,
        borderRadius: WingRadius.control,
      ),
      indicatorSize: TabBarIndicatorSize.tab,
      dividerColor: tokens.border,
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: tokens.raised,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: tokens.raised,
      surfaceTintColor: Colors.transparent,
      shape: panelShape,
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(
          fontFamily: WingTypography.sans,
          color: tokens.onSurface,
          fontSize: 14,
        ),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(tokens.raised),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(panelShape),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      disabledColor: tokens.muted,
      textStyle: TextStyle(
        fontFamily: WingTypography.sans,
        color: tokens.onSurface,
        fontSize: 16,
      ),
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(tokens.raised),
        shape: WidgetStatePropertyAll(panelShape),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: tokens.raised,
      surfaceTintColor: Colors.transparent,
      shape: panelShape,
      titleTextStyle: tokens.typography.section.copyWith(
        color: tokens.onSurface,
      ),
      contentTextStyle: tokens.typography.body.copyWith(
        color: tokens.onSurface,
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: tokens.raised,
        borderRadius: WingRadius.control,
        border: Border.all(color: tokens.border),
      ),
      textStyle: TextStyle(
        fontFamily: WingTypography.sans,
        color: tokens.onSurface,
        fontSize: 12,
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) =>
            !states.contains(WidgetState.disabled) &&
                states.contains(WidgetState.selected)
            ? onAccent
            : tokens.muted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) =>
            !states.contains(WidgetState.disabled) &&
                states.contains(WidgetState.selected)
            ? tokens.accent
            : tokens.border,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      checkColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    radioTheme: RadioThemeData(
      materialTapTargetSize: MaterialTapTargetSize.padded,
      fillColor: WidgetStateProperty.resolveWith(
        (states) =>
            !states.contains(WidgetState.disabled) &&
                states.contains(WidgetState.selected)
            ? tokens.accent
            : tokens.muted,
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: tokens.accent,
      selectionColor: tokens.accent.withValues(alpha: .25),
      selectionHandleColor: tokens.accent,
    ),
    cardTheme: CardThemeData(
      color: tokens.raised,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: WingRadius.card,
        side: BorderSide(color: tokens.border),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: tokens.border,
      space: 1,
      thickness: 1,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: tokens.accent,
      foregroundColor: onAccent,
      shape: actionShape,
      elevation: 0,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      clipBehavior: Clip.antiAlias,
      backgroundColor: tokens.raised,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: WingRadius.sheet),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: tokens.raised,
      contentTextStyle: tokens.typography.body.copyWith(
        color: tokens.onSurface,
      ),
      behavior: SnackBarBehavior.floating,
      actionTextColor: tokens.accent,
      disabledActionTextColor: tokens.muted,
      shape: panelShape,
    ),
    extensions: <ThemeExtension<dynamic>>[tokens],
  );
}

/// One paint-only tap response for Wing controls, including disabled controls.
/// The child retains activation, semantics, focus and gesture admission.
class StudioButtonPress extends StatefulWidget {
  const StudioButtonPress({super.key, required this.child});

  final Widget child;

  @override
  State<StudioButtonPress> createState() => _StudioButtonPressState();
}

class _StudioButtonPressState extends State<StudioButtonPress> {
  // Hit paths dispatch from the innermost target outwards. A nested action
  // claims its pointer first, so tapping it never compresses the enclosing row.
  static final Map<int, _StudioButtonPressState> _targets = {};
  Timer? _hold;
  int? _pointer;
  Offset? _origin;
  bool _compressed = false;

  void _down(PointerDownEvent event) {
    if (!mounted ||
        _pointer != null ||
        _targets.containsKey(event.pointer) ||
        event.buttons != kPrimaryButton) {
      return;
    }
    _targets[event.pointer] = this;
    _pointer = event.pointer;
    _origin = event.position;
    _hold?.cancel();
    setState(() => _compressed = true);
    // Feedback stays visible for short taps; callbacks run on their own timing.
    _hold = Timer(WingMotion.buttonPress, () {
      if (mounted && _pointer == null) setState(() => _compressed = false);
    });
  }

  void _move(PointerMoveEvent event) {
    if (_pointer == event.pointer &&
        (event.position - _origin!).distance > kTouchSlop) {
      _release(event.pointer, cancelled: true);
    }
  }

  void _release(int pointer, {bool cancelled = false}) {
    if (!mounted || _pointer != pointer) return;
    _targets.remove(pointer);
    _pointer = null;
    _origin = null;
    if (cancelled) _hold?.cancel();
    if (cancelled || !(_hold?.isActive ?? false)) {
      setState(() => _compressed = false);
    }
  }

  @override
  void dispose() {
    if (_pointer != null) _targets.remove(_pointer);
    _pointer = null;
    _origin = null;
    _hold?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Listener(
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: (event) => _release(event.pointer),
      onPointerCancel: (event) => _release(event.pointer, cancelled: true),
      child: TweenAnimationBuilder<double>(
        tween: Tween(
          end: _compressed && !reduceMotion ? WingMotion.buttonPressedScale : 1,
        ),
        duration: reduceMotion
            ? Duration.zero
            : _compressed
            ? WingMotion.buttonPress
            : WingMotion.buttonRelease,
        curve: WingMotion.curve,
        child: widget.child,
        builder: (context, scale, child) => Transform.scale(
          key: const ValueKey('studio-button-press-transform'),
          scale: scale,
          transformHitTests: false,
          child: child,
        ),
      ),
    );
  }
}

/// Menu entries preserve PopupMenuEntry's value, height and dismissal contract.
class StudioPopupMenuItem<T> extends PopupMenuItem<T> {
  const StudioPopupMenuItem({
    super.key,
    super.value,
    super.onTap,
    super.enabled,
    super.height,
    super.padding,
    super.textStyle,
    super.labelTextStyle,
    super.mouseCursor,
    required super.child,
  });

  @override
  PopupMenuItemState<T, StudioPopupMenuItem<T>> createState() =>
      _StudioPopupMenuItemState<T>();
}

class _StudioPopupMenuItemState<T>
    extends PopupMenuItemState<T, StudioPopupMenuItem<T>> {
  @override
  Widget build(BuildContext context) =>
      StudioButtonPress(child: super.build(context));
}

// Framework-generated Back, dropdown and menu buttons receive the same press.
// Explicit action wrappers already cover their full control, so do not nest it.
Widget _studioButtonLayer(
  BuildContext context,
  Set<WidgetState> states,
  Widget? child,
) {
  final contents = child ?? const SizedBox.shrink();
  return context.findAncestorWidgetOfExactType<StudioButtonPress>() != null
      ? contents
      : StudioButtonPress(child: contents);
}

/// Checked menu entries retain their native checkmark and selection behavior.
class StudioCheckedPopupMenuItem<T> extends PopupMenuEntry<T> {
  const StudioCheckedPopupMenuItem({super.key, required this.entry});
  final CheckedPopupMenuItem<T> entry;
  @override
  double get height => entry.height;
  @override
  bool represents(T? value) => entry.represents(value);
  @override
  State<StudioCheckedPopupMenuItem<T>> createState() =>
      _StudioCheckedMenuState<T>();
}

class _StudioCheckedMenuState<T> extends State<StudioCheckedPopupMenuItem<T>> {
  @override
  Widget build(BuildContext context) => StudioButtonPress(child: widget.entry);
}
