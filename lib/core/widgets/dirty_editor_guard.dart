import 'package:flutter/material.dart';
import 'server_connection_label.dart';
import 'workspace_profile_navigation.dart';

/// Keeps transient editor input on its owning route until discard is confirmed.
/// The route's pop disposition also prevents profile/connection replacement.
class DirtyEditorGuard extends StatefulWidget {
  const DirtyEditorGuard({
    super.key,
    required this.dirty,
    required this.busy,
    required this.confirmDiscard,
    required this.child,
  });

  final bool dirty;
  final bool busy;
  final Future<bool> Function() confirmDiscard;
  final Widget child;

  @override
  State<DirtyEditorGuard> createState() => _DirtyEditorGuardState();
}

class _DirtyEditorGuardState extends State<DirtyEditorGuard> {
  bool _leaving = false;
  bool _confirming = false;
  WorkspaceProfileNavigation? _navigation;
  ModalRoute<dynamic>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final navigation = ServerConnectionScope.scopeOf(
      context,
    )?.profileNavigation;
    final route = ModalRoute.of(context);
    if (_navigation == navigation && _route == route) return;
    if (_route != null) _navigation?.unregisterLeaveGuard(_route!);
    _navigation = navigation;
    _route = route;
    if (route != null) navigation?.registerLeaveGuard(route, _confirmLeave);
  }

  @override
  void dispose() {
    if (_route != null) _navigation?.unregisterLeaveGuard(_route!);
    super.dispose();
  }

  Future<bool> _confirmLeave() async {
    if (widget.busy || _confirming) return false;
    _confirming = true;
    try {
      final approved = !widget.dirty || await widget.confirmDiscard();
      return approved && mounted && !widget.busy;
    } finally {
      _confirming = false;
    }
  }

  Future<void> _requestClose() async {
    if (!await _confirmLeave()) return;
    setState(() => _leaving = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _leaving || (!widget.dirty && !widget.busy),
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _requestClose();
    },
    child: widget.child,
  );
}
