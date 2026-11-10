import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../../models/health_alert.dart';
import '../../presentation/health_alert_presentation.dart';
import '../../theme/wing_theme.dart';
import 'health_alerts_scope.dart';

/// One transient notice per application, independent of how many headers are
/// mounted. Never opens a modal automatically or requests native notification.
class HealthAlertNotice extends StatefulWidget {
  const HealthAlertNotice({
    super.key,
    required this.child,
    required this.navigatorKey,
  });

  /// Opening the incident review replaces its transient announcement.
  static void dismiss(BuildContext context) {
    final notice = context.findAncestorStateOfType<_HealthAlertNoticeState>();
    notice?._expiry?.cancel();
    notice?._hide();
  }

  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;
  @override
  State<HealthAlertNotice> createState() => _HealthAlertNoticeState();
}

class _HealthAlertNoticeState extends State<HealthAlertNotice> {
  HealthAlertsScope? _scope;
  final _seen = <String, int>{};
  HealthAlert? _notice;
  Timer? _expiry;
  OverlayEntry? _entry;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = HealthAlertsScope.maybeOf(context);
    if (next?.alerts != _scope?.alerts) {
      _scope?.alerts.removeListener(_changed);
      _scope = next;
      _scope?.alerts.addListener(_changed);
      for (final a in _scope?.alerts.alerts ?? <HealthAlert>[]) {
        if (a.remindsAt(_scope!.alerts.now)) _seen[a.id] = a.occurrence;
      }
    }
  }

  void _changed() {
    if (!mounted || _scope == null) return;
    final alerts = _scope!.alerts.alerts
        .where((a) => a.remindsAt(_scope!.alerts.now))
        .toList();
    final fresh = alerts.where((a) => _seen[a.id] != a.occurrence).firstOrNull;
    _seen
      ..clear()
      ..addEntries(alerts.map((a) => MapEntry(a.id, a.occurrence)));
    final visible =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (fresh != null &&
        visible &&
        _scope!.alerts.settings.settings.showNotice) {
      _expiry?.cancel();
      _notice = fresh;
      _show();
      _expiry = Timer(const Duration(milliseconds: 5500), () {
        if (mounted) _hide();
      });
    } else if (_notice != null &&
        (!visible || !alerts.any((a) => a.id == _notice!.id))) {
      _expiry?.cancel();
      _hide();
    }
  }

  void _hide() {
    _notice = null;
    _entry?.remove();
    _entry?.dispose();
    _entry = null;
  }

  void _show() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _notice != null) _show();
      });
      return;
    }
    final overlay = widget.navigatorKey.currentState?.overlay;
    if (overlay == null) return;
    if (_entry != null) {
      _entry!.markNeedsBuild();
      return;
    }
    _entry = OverlayEntry(builder: _renderNotice);
    overlay.insert(_entry!);
  }

  @override
  Widget build(BuildContext context) => widget.child;
  Widget _renderNotice(BuildContext context) {
    final tokens = WingTokens.of(context), notice = _notice;
    if (notice == null) return const SizedBox.shrink();
    final media = MediaQuery.of(context);
    final severityColor = notice.severity == HealthAlertSeverity.critical
        ? tokens.danger
        : tokens.warning;
    final largeText = media.textScaler.scale(16) >= 24;
    final statusIcon = Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: severityColor.withValues(alpha: 0.12),
        borderRadius: WingRadius.control,
      ),
      child: Icon(
        notice.severity == HealthAlertSeverity.critical
            ? Icons.error_outline
            : Icons.warning_amber_rounded,
        color: severityColor,
        size: 20,
      ),
    );
    final labels = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          notice.title,
          style: tokens.typography.section.copyWith(color: tokens.onSurface),
        ),
        if (healthAlertTriggerSummary(notice) case final summary?) ...[
          const SizedBox(height: WingSpacing.xs),
          Text(
            summary,
            style: tokens.typography.label.copyWith(
              fontSize: 13,
              color: tokens.onSurface,
            ),
          ),
        ],
        const SizedBox(height: WingSpacing.xs),
        Text(
          notice.connectionLabel,
          style: tokens.typography.label.copyWith(color: tokens.muted),
        ),
      ],
    );
    final openArea = Tooltip(
      message: healthAlertActionLabel(notice),
      child: StudioButtonPress(
        child: InkWell(
          onTap: () {
            _expiry?.cancel();
            _hide();
            _scope?.openAlert(notice);
          },
          child: Padding(
            padding: const EdgeInsets.all(WingSpacing.md),
            child: largeText
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      statusIcon,
                      const SizedBox(height: WingSpacing.sm),
                      labels,
                    ],
                  )
                : Row(
                    children: [
                      statusIcon,
                      const SizedBox(width: WingSpacing.md),
                      Expanded(child: labels),
                    ],
                  ),
          ),
        ),
      ),
    );
    final dismiss = StudioButtonPress(
      child: IconButton(
        tooltip: 'Dismiss health notice',
        color: tokens.muted,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        onPressed: () {
          _expiry?.cancel();
          _hide();
        },
        icon: const Icon(Icons.close, size: 20),
      ),
    );
    return Positioned(
      // Leave a generous gap below the compact toolbar, growing with text.
      // Keep the notice clear of the composer and keyboard.
      top: media.padding.top + media.textScaler.scale(48) + WingSpacing.xl * 2,
      left: media.padding.left + WingSpacing.xl,
      right: media.padding.right + WingSpacing.xl,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: TweenAnimationBuilder<double>(
            key: ValueKey((notice.id, notice.occurrence)),
            tween: Tween(begin: 0, end: 1),
            duration: media.disableAnimations || media.accessibleNavigation
                ? Duration.zero
                : WingMotion.standard,
            curve: WingMotion.curve,
            builder: (context, value, child) => Opacity(
              opacity: value,
              child: Transform.translate(
                offset: Offset(0, -WingSpacing.sm * (1 - value)),
                child: child,
              ),
            ),
            child: Material(
              key: const ValueKey('health-alert-notice-card'),
              color: tokens.raised,
              elevation: 6,
              shadowColor: Colors.black.withValues(alpha: 0.24),
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: WingRadius.card,
                side: BorderSide(color: tokens.border),
              ),
              child: Semantics(
                liveRegion: true,
                child: largeText
                    ? Stack(
                        children: [
                          SizedBox(width: double.infinity, child: openArea),
                          PositionedDirectional(
                            top: 0,
                            end: WingSpacing.xs,
                            child: dismiss,
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(child: openArea),
                          dismiss,
                          const SizedBox(width: WingSpacing.xs),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _scope?.alerts.removeListener(_changed);
    _expiry?.cancel();
    _hide();
    super.dispose();
  }
}
