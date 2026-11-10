part of 'studio_error.dart';

/// Report a transient failure at the control that triggered it.
///
/// The anchor must have the control's own bounds. Concurrent reports with the
/// same underlying [errorKey] share one presentation and one timer. Call
/// [dismissTransientError] when starting a fresh attempt.
void showTransientError(
  BuildContext anchorContext,
  String message, {
  required Object errorKey,
  IconData? icon,
  StudioErrorSeverity severity = StudioErrorSeverity.error,
  String? detail,
}) => _showTransientError(
  anchorContext,
  message,
  errorKey: errorKey,
  icon: icon,
  severity: severity,
  detail: detail,
  rememberCause: true,
);

void _showTransientError(
  BuildContext anchorContext,
  String message, {
  required Object errorKey,
  required IconData? icon,
  required StudioErrorSeverity severity,
  required String? detail,
  required bool rememberCause,
}) {
  if (!anchorContext.mounted) return;
  final overlay = Overlay.maybeOf(anchorContext, rootOverlay: true);
  if (overlay == null) return;
  final route = ModalRoute.of(anchorContext);
  if (route?.isCurrent == false) return;
  final layer = _errorLayers[overlay] ??= _TransientErrorLayer(overlay);
  layer.show(
    _TransientError(
      anchor: anchorContext,
      route: route,
      key: errorKey,
      message: message,
      detail: detail,
      severity: severity,
      icon: icon,
      themes: InheritedTheme.capture(from: anchorContext, to: overlay.context),
      sourceMedia: anchorContext
          .getInheritedWidgetOfExactType<MediaQuery>()
          ?.data,
    ),
    rememberCause: rememberCause,
  );
}

/// Clear feedback on a retry. A supplied cause also clears the same notice
/// reported by a different affected control.
void dismissTransientError(BuildContext anchorContext, {Object? errorKey}) {
  if (!anchorContext.mounted) return;
  final overlay = Overlay.maybeOf(anchorContext, rootOverlay: true);
  if (overlay == null) return;
  _errorLayers[overlay]?.dismiss(
    anchorContext,
    route: ModalRoute.of(anchorContext),
    key: errorKey,
  );
}

/// Presents new owner-issued failure events at the bounds of [child].
///
/// An event already present when the control mounts belongs to an earlier
/// visit. A retry publishes a new identity or clears the current one.
class StudioTransientErrorAnchor extends StatefulWidget {
  const StudioTransientErrorAnchor({
    super.key,
    required this.child,
    required this.errorKey,
    required this.message,
    this.detail,
    this.icon,
    this.severity = StudioErrorSeverity.noResult,
  });

  final Widget child;
  final Object? errorKey;
  final String? message;
  final String? detail;
  final IconData? icon;
  final StudioErrorSeverity severity;

  @override
  State<StudioTransientErrorAnchor> createState() =>
      _StudioTransientErrorAnchorState();
}

class _StudioTransientErrorAnchorState
    extends State<StudioTransientErrorAnchor> {
  @override
  void didUpdateWidget(StudioTransientErrorAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.errorKey != oldWidget.errorKey ||
        (widget.message == null) != (oldWidget.message == null)) {
      _schedulePresentation();
    }
  }

  void _schedulePresentation() {
    final event = widget.errorKey;
    final message = widget.message;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.errorKey != event || widget.message != message) {
        return;
      }
      dismissTransientError(context);
      if (event != null && message != null) {
        _showTransientError(
          context,
          message,
          errorKey: event,
          detail: widget.detail,
          icon: widget.icon,
          severity: widget.severity,
          rememberCause: false,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

final _errorLayers = Expando<_TransientErrorLayer>();

class _TransientError {
  _TransientError({
    required this.anchor,
    required this.route,
    required this.key,
    required this.message,
    required this.detail,
    required this.severity,
    required this.icon,
    required this.themes,
    required this.sourceMedia,
  });

  final BuildContext anchor;
  final ModalRoute<dynamic>? route;
  final Object key;
  final String message;
  final String? detail;
  final StudioErrorSeverity severity;
  final IconData? icon;
  final CapturedThemes themes;
  final contentKey = GlobalKey();

  MediaQueryData? sourceMedia;
  Rect? position;
  Size? constraints;
  Timer? expiry;
  bool displayed = false;
}

typedef _AnchorBounds = ({Rect control, Rect affected});

/// One overlay per Navigator overlay. The layer is active only while a notice
/// is pending or visible. Geometry follows rendered frames without polling or
/// keeping an animation running while the UI is idle.
class _TransientErrorLayer with WidgetsBindingObserver {
  _TransientErrorLayer(this.overlay);

  static const _lifetime = Duration(seconds: 4);
  static const _preferredGap = 28.0;
  static const _minimumGap = 4.0;
  static const _compactGap = 12.0;
  static const _maximumWidth = 340.0;
  static const _minimumHeight = 56.0;

  final OverlayState overlay;
  final _notices = <_TransientError>[];
  final _routeCauses = Expando<Map<Object, WeakReference<BuildContext>>>();
  final _overlayCauses = <Object, WeakReference<BuildContext>>{};
  OverlayEntry? _entry;

  Map<Object, WeakReference<BuildContext>> _causes(
    ModalRoute<dynamic>? route,
  ) => route == null ? _overlayCauses : (_routeCauses[route] ??= {});

  void show(_TransientError notice, {required bool rememberCause}) {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if ((lifecycle != null && lifecycle != AppLifecycleState.resumed) ||
        _notices.any((existing) => existing.key == notice.key)) {
      return;
    }
    if (rememberCause) {
      final causes = _causes(notice.route);
      causes.removeWhere((_, anchor) => anchor.target?.mounted != true);
      if (causes.containsKey(notice.key)) return;
      causes[notice.key] = WeakReference(notice.anchor);
    }
    _notices.add(notice);
    if (_entry != null) {
      _entry!.markNeedsBuild();
      return;
    }
    final entry = OverlayEntry(builder: _build);
    _entry = entry;
    overlay.insert(entry);
    WidgetsBinding.instance.addObserver(this);
    _watch(entry);
  }

  void dismiss(
    BuildContext anchor, {
    required ModalRoute<dynamic>? route,
    Object? key,
  }) {
    final causes = _causes(route);
    if (key == null) {
      causes.removeWhere((_, source) => identical(source.target, anchor));
    } else {
      causes.remove(key);
    }
    for (final notice in _notices.toList()) {
      if (key == null ? identical(notice.anchor, anchor) : notice.key == key) {
        _remove(notice);
      }
    }
  }

  void _remove(_TransientError notice) {
    if (!_notices.remove(notice)) return;
    notice.expiry?.cancel();
    if (_notices.isNotEmpty) {
      _entry?.markNeedsBuild();
      return;
    }
    _entry?.remove();
    _entry?.dispose();
    _entry = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      for (final notice in _notices.toList()) {
        _remove(notice);
      }
    }
  }

  void _watch(OverlayEntry entry) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!identical(_entry, entry)) return;
      _layoutNotices();
      if (identical(_entry, entry)) _watch(entry);
    });
  }

  void _layoutNotices() {
    if (!overlay.mounted) {
      for (final notice in _notices.toList()) {
        _remove(notice);
      }
      return;
    }
    final surface = overlay.context.findRenderObject() as RenderBox;
    final media = MediaQuery.of(overlay.context);
    final viewport = Rect.fromLTRB(
      media.padding.left + WingSpacing.md,
      media.padding.top + WingSpacing.md,
      surface.size.width - media.padding.right - WingSpacing.md,
      surface.size.height -
          math.max(media.padding.bottom, media.viewInsets.bottom) -
          WingSpacing.md,
    );
    final anchors = <_TransientError, _AnchorBounds>{};
    for (final notice in _notices.toList()) {
      final anchor = _visibleAnchor(notice, surface, viewport);
      if (anchor == null) {
        _remove(notice);
      } else {
        anchors[notice] = anchor;
      }
    }

    final occupied = <Rect>[];
    var needsBuild = false;
    for (final notice in anchors.keys.toList().reversed) {
      final source = notice.anchor
          .getInheritedWidgetOfExactType<MediaQuery>()
          ?.data;
      if (source != notice.sourceMedia) {
        notice.sourceMedia = source;
        needsBuild = true;
      }
      if (notice.position != null && !notice.displayed) {
        // This frame painted the position calculated on the preceding frame.
        // Movement after that paint must not postpone the expiry.
        notice.displayed = true;
        unawaited(_startExpiry(notice));
      }
      final (:control, :affected) = anchors[notice]!;
      final useAffectedWidth = affected.width >= 216;
      final leftLimit = useAffectedWidth
          ? affected.left + WingSpacing.md
          : viewport.left;
      final rightLimit = useAffectedWidth
          ? affected.right - WingSpacing.md
          : viewport.right;
      final width = math.min(_maximumWidth, rightLimit - leftLimit);
      final above = affected.top - viewport.top;
      final below = viewport.bottom - affected.bottom;
      final available = math.max(above, below);
      final spaceForGap = available - _minimumHeight;
      if (spaceForGap < _minimumGap) {
        _remove(notice);
        continue;
      }
      final gap = spaceForGap >= _preferredGap
          ? _preferredGap
          : math.min(_compactGap, spaceForGap);
      final constraints = Size(width, available - gap);
      if (constraints != notice.constraints) {
        final needsMeasurement = width != notice.constraints?.width;
        notice.constraints = constraints;
        needsBuild = true;
        if (needsMeasurement) {
          notice.position = null;
          continue;
        }
      }
      final content = notice.contentKey.currentContext?.findRenderObject();
      if (content is! RenderBox || !content.hasSize) continue;
      final left = (control.center.dx - width / 2).clamp(
        leftLimit,
        rightLimit - width,
      );
      final height = math.min(content.size.height, constraints.height);
      final candidates = [
        if (above >= height + gap)
          Rect.fromLTWH(left, affected.top - height - gap, width, height),
        if (below >= height + gap)
          Rect.fromLTWH(left, affected.bottom + gap, width, height),
      ];
      final position = candidates.where((candidate) {
        return !occupied.any(candidate.overlaps) &&
            !anchors.values.any(
              (bounds) => candidate.overlaps(bounds.affected),
            );
      }).firstOrNull;
      if (position == null) {
        _remove(notice);
        continue;
      }
      occupied.add(position);
      if (notice.position != position) {
        notice.position = position;
        needsBuild = true;
      }
    }
    if (needsBuild) _entry?.markNeedsBuild();
  }

  _AnchorBounds? _visibleAnchor(
    _TransientError notice,
    RenderBox surface,
    Rect viewport,
  ) {
    if (!notice.anchor.mounted || notice.route?.isCurrent == false) {
      return null;
    }
    final anchor = notice.anchor.findRenderObject();
    if (anchor is! RenderBox || !anchor.attached || !anchor.hasSize) {
      return null;
    }
    final control = _visibleBounds(anchor, surface, viewport);
    if (control == null) return null;

    // A suffix action lives inside an input. Keep both the icon and the draft
    // clear, including when several lines make the field taller than the icon.
    var affected = control;
    notice.anchor.visitAncestorElements((element) {
      if (element.widget is! InputDecorator) return true;
      final input = element.findRenderObject();
      if (input is RenderBox && input.attached && input.hasSize) {
        final bounds = _visibleBounds(input, surface, viewport);
        if (bounds != null) affected = affected.expandToInclude(bounds);
      }
      return false;
    });
    return (control: control, affected: affected);
  }

  Rect? _visibleBounds(RenderBox box, RenderBox surface, Rect viewport) {
    var visible = MatrixUtils.transformRect(
      box.getTransformTo(surface),
      Offset.zero & box.size,
    ).intersect(viewport);
    RenderObject child = box;
    for (var parent = child.parent; parent != null; parent = child.parent) {
      if (identical(parent, surface)) break;
      if (parent is RenderOffstage && parent.offstage) return null;
      final clip = parent.describeApproximatePaintClip(child);
      if (clip != null) {
        visible = visible.intersect(
          MatrixUtils.transformRect(parent.getTransformTo(surface), clip),
        );
      }
      child = parent;
    }
    return visible.isFinite && !visible.isEmpty ? visible : null;
  }

  Future<void> _startExpiry(_TransientError notice) async {
    final elapsed = Stopwatch()..start();
    try {
      final recommendation = recommendedTextTimeout(_lifetime);
      final remaining = recommendation is Duration
          ? recommendation
          : (await recommendation) - elapsed.elapsed;
      if (_notices.contains(notice)) {
        notice.expiry = Timer(remaining, () => _remove(notice));
      }
    } catch (error, stack) {
      if (!_notices.contains(notice)) return;
      _remove(notice);
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          context: ErrorDescription('while reading the accessibility timeout'),
        ),
      );
    }
  }

  Widget _build(BuildContext context) {
    final viewport = MediaQuery.of(context);
    return Stack(
      children: [
        for (final notice in _notices)
          if (notice.constraints case final constraints?)
            _buildNotice(notice, constraints, viewport),
      ],
    );
  }

  Widget _buildNotice(
    _TransientError notice,
    Size constraints,
    MediaQueryData viewport,
  ) {
    // The source route can scale its text independently of the root overlay.
    // Keep the overlay's insets, which a Scaffold may consume at the source.
    final source = notice.sourceMedia;
    final media = viewport.copyWith(
      textScaler: source?.textScaler,
      boldText: viewport.boldText || (source?.boldText ?? false),
      highContrast: viewport.highContrast || (source?.highContrast ?? false),
      disableAnimations:
          viewport.disableAnimations || (source?.disableAnimations ?? false),
      accessibleNavigation:
          viewport.accessibleNavigation ||
          (source?.accessibleNavigation ?? false),
    );
    final motion = media.disableAnimations || media.accessibleNavigation
        ? Duration.zero
        : WingMotion.fast;
    final placed = notice.position != null;
    return Positioned(
      key: ObjectKey(notice),
      left: notice.position?.left ?? 0,
      top: notice.position?.top ?? 0,
      width: constraints.width,
      child: MediaQuery(
        data: media,
        child: IgnorePointer(
          ignoring: !placed,
          child: ExcludeSemantics(
            excluding: !placed,
            child: AnimatedOpacity(
              opacity: placed ? 1 : 0,
              duration: motion,
              child: Semantics(
                container: true,
                liveRegion: true,
                label: [notice.message, ?notice.detail].join('\n'),
                excludeSemantics: true,
                onDismiss: () => _remove(notice),
                child: Dismissible(
                  key: ObjectKey(notice),
                  direction: DismissDirection.horizontal,
                  movementDuration: motion,
                  resizeDuration: null,
                  onDismissed: (_) => _remove(notice),
                  child: ConstrainedBox(
                    key: notice.contentKey,
                    constraints: BoxConstraints(maxHeight: constraints.height),
                    child: notice.themes.wrap(
                      StudioErrorFrame(
                        floating: true,
                        severity: notice.severity,
                        child: SingleChildScrollView(
                          primary: false,
                          padding: const EdgeInsets.all(WingSpacing.lg),
                          child: StudioError._capsule(
                            notice.message,
                            detail: notice.detail,
                            icon: notice.icon,
                            severity: notice.severity,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
