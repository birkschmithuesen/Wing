import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:re_editor/re_editor.dart';

/// Native selection and copying, with handle links limited to the actual reader.
/// Selection geometry is sampled after layout; hidden anchors are unpublished so
/// Flutter excludes both their painting and their pointer targets.
class SelectionViewport extends StatefulWidget {
  const SelectionViewport({super.key, required this.child})
    : codeController = null,
      codeRender = null;
  const SelectionViewport.code({
    super.key,
    required this.child,
    required CodeLineEditingController controller,
    required this.codeRender,
  }) : codeController = controller;
  final Widget child;
  final CodeLineEditingController? codeController;
  final RenderBox? Function()? codeRender;
  @override
  State<SelectionViewport> createState() => _SelectionViewportState();
}

class _SelectionViewportState extends State<SelectionViewport> {
  final _key = GlobalKey();
  _AreaAnchors? _selectionArea;
  _AreaAnchors get _area => _selectionArea ??= (_AreaAnchors(() {
    if (!_active) return null;
    final render = _key.currentContext?.findRenderObject();
    return render is RenderBox && render.hasSize ? render : null;
  }, () => MediaQuery.sizeOf(context))..addListener(_changed));
  _HandleAnchors? _anchors;
  final _editables = <RenderEditable, _EditableAnchors>{};
  bool _focused = false;
  bool _queued = false;
  bool _active = true;

  void _changed() {
    if (_queued || !_active || !mounted) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (!_active || !mounted) return;
      _refresh();
      // Follow any frame which changes an ancestor clip or transform. Registering
      // a callback does not request another frame, so idle selection stays idle.
      if (_focused) _changed();
    });
  }

  void _refresh() {
    if (!_active) return;
    final root = _key.currentContext?.findRenderObject();
    if (root == null) return;
    if (widget.child is SelectionArea) {
      _area.refresh();
      return;
    }
    if (widget.codeController case final controller?) {
      final field = widget.codeRender!();
      if (field == null) return;
      if (_anchors?.render != field) _anchors = _CodeAnchors(field, controller);
    } else {
      final found = <RenderEditable>{};
      void visit(Element element) {
        // A nested native control has its own geometry owner.
        if (element.widget is SelectionViewport) return;
        if (element is RenderObjectElement &&
            element.renderObject is RenderEditable) {
          found.add(element.renderObject as RenderEditable);
        }
        element.visitChildElements(visit);
      }

      _key.currentContext!.visitChildElements(visit);
      _editables.removeWhere((render, anchors) {
        if (found.contains(render)) return false;
        if (render.attached) anchors.restore();
        return true;
      });
      for (final render in found) {
        _editables.putIfAbsent(render, () => _EditableAnchors(render));
      }
      for (final anchors in _editables.values) {
        if (_focused) {
          anchors.update(MediaQuery.sizeOf(context));
        } else {
          anchors.restore();
        }
      }
    }
    if (_focused) {
      _anchors?.update(MediaQuery.sizeOf(context));
    } else {
      _anchors?.restore();
    }
  }

  void _observe(bool focused) {
    _focused = focused;
    if (!_active) return;
    _changed();
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didUpdateWidget(covariant SelectionViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.codeController != widget.codeController) {
      if (_anchors?.render.attached == true) _anchors?.restore();
      _anchors = null;
    }
    if (_focused) _changed();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_focused) _changed();
  }

  @override
  void deactivate() {
    // Descendant selection containers release their handles before this State
    // is disposed. mounted is still true then, but render lookup is invalid.
    _active = false;
    _restoreAnchors();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
    _changed();
  }

  void _restoreAnchors() {
    if (_anchors?.render.attached == true) _anchors?.restore();
    for (final anchors in _editables.values) {
      if (anchors.render.attached) anchors.restore();
    }
  }

  @override
  void dispose() {
    _active = false;
    _restoreAnchors();
    _selectionArea?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final area = widget.child;
    final child = area is SelectionArea
        ? SelectionArea(
            key: area.key,
            focusNode: area.focusNode,
            selectionControls: area.selectionControls,
            contextMenuBuilder: area.contextMenuBuilder,
            magnifierConfiguration: area.magnifierConfiguration,
            onSelectionChanged: area.onSelectionChanged,
            child: SelectionContainer(delegate: _area, child: area.child),
          )
        : area;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: _observe,
      child: KeyedSubtree(key: _key, child: child),
    );
  }
}

Rect _selectionVisibleRect(RenderBox source, Size screenSize) {
  var rect = MatrixUtils.transformRect(
    source.getTransformTo(null)..invert(),
    Offset.zero & screenSize,
  );
  RenderObject child = source;
  for (
    RenderObject? ancestor = source.parent;
    ancestor != null;
    ancestor = ancestor.parent
  ) {
    final clip = ancestor.describeApproximatePaintClip(child);
    if (clip != null) {
      rect = rect.intersect(
        MatrixUtils.transformRect(ancestor.getTransformTo(source), clip),
      );
    }
    child = ancestor;
  }
  return rect;
}

abstract class _HandleAnchors {
  _HandleAnchors(this.render);
  final RenderBox render;
  void update(Size screenSize);
  void restore();
}

class _EditableAnchors extends _HandleAnchors {
  _EditableAnchors(RenderEditable super.render)
    : _start = render.startHandleLayerLink,
      _end = render.endHandleLayerLink;
  RenderEditable get editable => render as RenderEditable;
  LayerLink _start;
  LayerLink _end;
  final _hiddenStart = LayerLink();
  final _hiddenEnd = LayerLink();
  @override
  void update(Size screenSize) {
    if (editable.startHandleLayerLink != _hiddenStart) {
      _start = editable.startHandleLayerLink;
    }
    if (editable.endHandleLayerLink != _hiddenEnd) {
      _end = editable.endHandleLayerLink;
    }
    final selection = editable.selection;
    if (selection == null || !selection.isValid) {
      restore();
      return;
    }
    final points = editable.getEndpointsForSelection(selection);
    final visible = _selectionVisibleRect(editable, screenSize).inflate(.5);
    editable.startHandleLayerLink = visible.contains(points.first.point)
        ? _start
        : _hiddenStart;
    editable.endHandleLayerLink = visible.contains(points.last.point)
        ? _end
        : _hiddenEnd;
  }

  @override
  void restore() {
    editable.startHandleLayerLink = _start;
    editable.endHandleLayerLink = _end;
  }
}

/// re_editor 0.10 exposes public handle-link members on a private render type.
/// Its controller's public bindEditor callback supplies the render object without
/// depending on runtime names. Keep this package adaptation covered by CodeEditor
/// integration tests; no package internals are copied or modified.
class _CodeAnchors extends _HandleAnchors {
  _CodeAnchors(super.render, this.controller) {
    _start = field.startHandleLayerLink as LayerLink;
    _end = field.endHandleLayerLink as LayerLink;
  }
  final CodeLineEditingController controller;
  dynamic get field => render;
  late LayerLink _start;
  late LayerLink _end;
  final _hiddenStart = LayerLink();
  final _hiddenEnd = LayerLink();
  @override
  void update(Size screenSize) {
    if (field.startHandleLayerLink != _hiddenStart) {
      _start = field.startHandleLayerLink as LayerLink;
    }
    if (field.endHandleLayerLink != _hiddenEnd) {
      _end = field.endHandleLayerLink as LayerLink;
    }
    final visible = _selectionVisibleRect(render, screenSize).inflate(.5);
    final start =
        field.calculateTextPositionViewportOffset(controller.selection.start)
            as Offset?;
    final end =
        field.calculateTextPositionViewportOffset(controller.selection.end)
            as Offset?;
    final line = Offset(0, field.lineHeight as double);
    field.startHandleLayerLink = start != null && visible.contains(start + line)
        ? _start
        : _hiddenStart;
    field.endHandleLayerLink = end != null && visible.contains(end + line)
        ? _end
        : _hiddenEnd;
  }

  @override
  void restore() {
    field.startHandleLayerLink = _start;
    field.endHandleLayerLink = _end;
  }
}

Widget viewportSelection(Widget child) => SelectionViewport(
  key: child.key == null ? null : ValueKey(('selection-viewport', child.key)),
  child: child,
);

class _AreaAnchors extends StaticSelectionContainerDelegate {
  _AreaAnchors(this.source, this.screenSize);
  final RenderBox? Function() source;
  final Size Function() screenSize;
  LayerLink? _start;
  LayerLink? _end;
  @override
  void pushHandleLayers(LayerLink? startHandle, LayerLink? endHandle) {
    _start = startHandle;
    _end = endHandle;
    refresh();
  }

  void refresh() {
    final render = source();
    if (render == null || !hasSize) return;
    final visible = _selectionVisibleRect(render, screenSize()).inflate(.5);
    bool contains(SelectionPoint? point) =>
        point != null &&
        visible.contains(
          MatrixUtils.transformPoint(
            getTransformTo(render),
            point.localPosition,
          ),
        );
    super.pushHandleLayers(
      contains(value.startSelectionPoint) ? _start : null,
      contains(value.endSelectionPoint) ? _end : null,
    );
  }
}
