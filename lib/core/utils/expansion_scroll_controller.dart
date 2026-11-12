import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import '../widgets/anchored_expansion_tile.dart';

/// Corrects disclosure movement during layout, before a frame is painted.
class ExpansionScrollController extends ScrollController {
  ExpansionScrollController({
    required this.preserveViewportPosition,
    super.initialScrollOffset,
  });

  // Input navigation must align controls with the new viewport bounds; ordinary
  // reading instead retains the visible row while lower chrome changes height.
  final bool Function() preserveViewportPosition;

  ExpansionAnchorBox? _anchor;
  bool _allowBottomGap = true;
  bool _reflow = false;
  double _pendingHeight = 0;
  TranscriptAnchorBox? _readerAnchor;
  TranscriptAnchorBox? Function()? _readerReplacement;
  double _readerTop = 0;

  bool get hasExpansionAnchor => _anchor?.attached == true;

  TranscriptAnchorBox? get expansionRow {
    RenderObject? row = _anchor;
    while (row != null && row is! TranscriptAnchorBox) {
      row = row.parent;
    }
    return row as TranscriptAnchorBox?;
  }

  /// Capture the reading position before new content is laid out. Correcting
  /// during layout avoids a visible jump and leaves drag/fling activities alive.
  void preserveReaderAnchor(
    TranscriptAnchorBox? anchor, {
    TranscriptAnchorBox? Function()? replacement,
  }) {
    _readerAnchor = anchor;
    _readerReplacement = replacement;
    if (anchor == null) return;
    _readerTop = anchor.leadingOffset;
  }

  /// A width change invalidates space reserved for a previous row geometry.
  /// Keep the captured reader anchor, but constrain it to the reflowed content.
  void prepareForReflow() {
    releaseExpansionAnchor();
    _reflow = true;
    for (final position in positions.cast<_ExpansionScrollPosition>()) {
      position._expansionScrollExtent = 0;
      position._expansionMinScrollExtent = 0;
    }
  }

  void anchorExpansion(BuildContext context, {required bool allowBottomGap}) {
    final box = context.findRenderObject();
    if (box is! ExpansionAnchorBox || !box.attached || !box.hasSize) return;
    releaseExpansionAnchor();
    _anchor = box;
    _allowBottomGap = allowBottomGap;
    if (expansionRow == null) {
      box.onHeightChanged = (delta) => _pendingHeight += delta;
    }
  }

  /// Includes asynchronous height changes in newer rows, even when the
  /// disclosure itself is outside the current sliver layout pass.
  void recordRowHeightChange(TranscriptAnchorBox row, double delta) {
    final anchoredRow = expansionRow;
    if (!hasExpansionAnchor || anchoredRow == null || delta == 0) return;
    int? indexOf(RenderObject object) {
      while (object.parent != null &&
          object.parent is! RenderSliverMultiBoxAdaptor) {
        object = object.parent!;
      }
      final data = object.parentData;
      return data is SliverMultiBoxAdaptorParentData ? data.index : null;
    }

    final index = indexOf(row);
    final anchorIndex = indexOf(anchoredRow);
    final sliver = row.parentSliver;
    if (index != null &&
        anchorIndex != null &&
        index <= anchorIndex &&
        identical(sliver, anchoredRow.parentSliver)) {
      if (sliver?.constraints.growthDirection == GrowthDirection.reverse) {
        if (index < anchorIndex) _pendingHeight -= delta;
      } else {
        _pendingHeight += delta;
      }
    }
  }

  void releaseExpansionAnchor() {
    _anchor?.onHeightChanged = null;
    _anchor = null;
    _pendingHeight = 0;
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _ExpansionScrollPosition(
    controller: this,
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
  );

  @override
  void dispose() {
    releaseExpansionAnchor();
    super.dispose();
  }
}

class _ExpansionScrollPosition extends ScrollPositionWithSingleContext {
  _ExpansionScrollPosition({
    required this.controller,
    required super.physics,
    required super.context,
    required super.initialPixels,
    required super.keepScrollOffset,
    super.oldPosition,
  });

  final ExpansionScrollController controller;
  double _expansionScrollExtent = 0;
  double _expansionMinScrollExtent = 0;

  @override
  void correctBy(double correction) {
    // The sliver has already applied this part of the row-height change.
    if (controller.hasExpansionAnchor) controller._pendingHeight -= correction;
    super.correctBy(correction);
  }

  @override
  void jumpTo(double value) {
    controller.preserveReaderAnchor(null);
    controller.releaseExpansionAnchor();
    if (value <= 0) {
      _expansionScrollExtent = 0;
      _expansionMinScrollExtent = 0;
    }
    super.jumpTo(value);
  }

  @override
  Future<void> animateTo(
    double to, {
    required Duration duration,
    required Curve curve,
  }) {
    controller.preserveReaderAnchor(null);
    controller.releaseExpansionAnchor();
    if (to <= 0) {
      _expansionScrollExtent = 0;
      _expansionMinScrollExtent = 0;
    }
    return super.animateTo(to, duration: duration, curve: curve);
  }

  @override
  void pointerScroll(double delta) {
    controller.releaseExpansionAnchor();
    super.pointerScroll(delta);
  }

  @override
  bool applyViewportDimension(double nextViewport) {
    final previous = hasViewportDimension ? viewportDimension : null;
    final accepted = super.applyViewportDimension(nextViewport);
    if (!controller._reflow &&
        previous != null &&
        controller.preserveViewportPosition() &&
        hasPixels &&
        axisDirection == AxisDirection.up &&
        pixels > minScrollExtent + .5 &&
        !isScrollingNotifier.value &&
        previous != nextViewport) {
      // Bottom controls can animate through several heights without a new
      // transcript update. Keep the visible row fixed through every frame.
      final target = (pixels + previous - nextViewport).clamp(
        minScrollExtent,
        double.infinity,
      );
      correctPixels(target);
      _expansionScrollExtent = target;
    }
    return accepted;
  }

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final reader =
        controller._readerReplacement?.call() ?? controller._readerAnchor;
    controller._readerAnchor = null;
    controller._readerReplacement = null;
    final delta = controller._pendingHeight;
    controller._pendingHeight = 0;
    if (controller._reflow) {
      final movement = reader?.attached == true
          ? reader!.leadingOffset - controller._readerTop
          : 0.0;
      final target = (pixels + movement).clamp(
        minScrollExtent,
        maxScrollExtent,
      );
      if ((target - pixels).abs() > .01) {
        correctPixels(target);
        return false;
      }
      controller._reflow = false;
    } else if (axisDirection == AxisDirection.up && reader?.attached == true) {
      // Content coordinates exclude user movement. The anchor also includes
      // disclosure growth, so do not apply that height correction a second time.
      final movement = reader!.leadingOffset - controller._readerTop;
      final target = pixels + movement;
      _expansionMinScrollExtent = target < minScrollExtent ? target : 0;
      _expansionScrollExtent = target > 0 ? target : 0;
      if ((target - pixels).abs() > 0.01) {
        // Reader movement already includes any expansion height consumed above.
        // Do not subtract it again into the next pass's pending correction.
        correctPixels(target);
        return false;
      }
    } else if (axisDirection == AxisDirection.up && delta.abs() > 0.01) {
      final corrected = pixels + delta;
      final target = controller._allowBottomGap
          ? corrected
          : corrected.clamp(minScrollExtent, double.infinity);
      // A large panel can shrink past the natural bottom of a reversed list.
      // Retain room below it so the tab/header stays at the tapped position.
      _expansionMinScrollExtent = target < minScrollExtent ? target : 0;
      // Lazy sliver estimates can change on the next layout pass. Retain the
      // corrected position even when the first estimate appears to contain it.
      _expansionScrollExtent = target > 0 ? target : 0;
      if ((target - pixels).abs() > 0.01) {
        correctPixels(target);
        return false;
      }
    }
    if (controller.hasExpansionAnchor && !controller._allowBottomGap) {
      // A closed disclosure no longer needs room below the content. Retire
      // any range retained by an earlier tab switch, including zero-delta frames.
      _expansionMinScrollExtent = 0;
      if (pixels < minScrollExtent) {
        correctPixels(minScrollExtent);
        return false;
      }
    }
    return super.applyContentDimensions(
      minScrollExtent < _expansionMinScrollExtent
          ? minScrollExtent
          : _expansionMinScrollExtent,
      maxScrollExtent > _expansionScrollExtent
          ? maxScrollExtent
          : _expansionScrollExtent,
    );
  }
}

/// Measures a transcript item's top edge in the reversed list's coordinates.
/// The measured height is retained by its own render object so the viewport
/// never reads a descendant's size while laying itself out.
class TranscriptScrollAnchor extends SingleChildRenderObjectWidget {
  const TranscriptScrollAnchor({
    super.key,
    required super.child,
    this.initialHeight = 0,
    this.onHeightChanged,
    this.onDetached,
  });

  final double initialHeight;
  final ValueChanged<TranscriptAnchorBox>? onDetached;
  final void Function(TranscriptAnchorBox row, double height)? onHeightChanged;

  @override
  TranscriptAnchorBox createRenderObject(BuildContext context) =>
      TranscriptAnchorBox(initialHeight)
        ..onHeightChanged = onHeightChanged
        ..onDetached = onDetached;

  @override
  void updateRenderObject(
    BuildContext context,
    TranscriptAnchorBox renderObject,
  ) {
    renderObject.onHeightChanged = onHeightChanged;
    renderObject.onDetached = onDetached;
  }
}

class TranscriptAnchorBox extends RenderProxyBox {
  TranscriptAnchorBox([this._height = 0]);

  double _height;
  ValueChanged<TranscriptAnchorBox>? onDetached;
  bool get contentPending => _pendingContent.isNotEmpty;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    // A keyed row can move between the latest and bookmarked slivers without
    // changing constraints. Re-register its geometry after detach retired it.
    markNeedsLayout();
  }

  @override
  void detach() {
    onDetached?.call(this);
    super.detach();
  }

  void Function(TranscriptAnchorBox row, double height)? onHeightChanged;
  final _pendingContent = <Object>{};
  bool _pendingLayoutScheduled = false;

  void setContentPending(Object source, bool pending) {
    final changed = pending
        ? _pendingContent.add(source)
        : _pendingContent.remove(source);
    if (!changed || !attached) return;
    // A bounded Markdown viewport can rebuild during its own layout after this
    // ancestor has finished. Keep pending geometry synchronous, but invalidate
    // the row outside that layout pass so retained heights also release.
    final scheduler = SchedulerBinding.instance;
    if (scheduler.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      if (_pendingLayoutScheduled) return;
      _pendingLayoutScheduled = true;
      scheduler.addPostFrameCallback((_) {
        _pendingLayoutScheduled = false;
        if (attached) markNeedsLayout();
      });
    } else {
      markNeedsLayout();
    }
  }

  RenderSliverMultiBoxAdaptor? get parentSliver {
    RenderObject item = this;
    while (item.parent != null && item.parent is! RenderSliverMultiBoxAdaptor) {
      item = item.parent!;
    }
    return item.parent is RenderSliverMultiBoxAdaptor
        ? item.parent! as RenderSliverMultiBoxAdaptor
        : null;
  }

  double get leadingOffset {
    RenderObject item = this;
    while (item.parent != null && item.parent is! RenderSliverMultiBoxAdaptor) {
      item = item.parent!;
    }
    final data = item.parentData;
    final offset = data is SliverMultiBoxAdaptorParentData
        ? data.layoutOffset ?? 0
        : 0;
    final sliver = parentSliver;
    final preceding = sliver?.constraints.precedingScrollExtent ?? 0;
    return sliver?.constraints.growthDirection == GrowthDirection.reverse
        ? -(preceding + offset)
        : preceding + offset + _height;
  }

  @override
  void performLayout() {
    super.performLayout();
    // A lazy row may be recreated while its Markdown worker is preparing.
    // Retain its measured geometry until the real content is ready again.
    if (_pendingContent.isNotEmpty && size.height < _height) {
      size = constraints.constrain(Size(size.width, _height));
    }
    _height = size.height;
    onHeightChanged?.call(this, size.height);
  }
}
