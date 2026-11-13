import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reveal a mounted control after its route is current and has finished opening.
/// A keyboard can leave a loaded control below the viewport indefinitely; a
/// passive hit-test wait cannot recover it. Lazy list discovery stays with the
/// caller, which knows the owning scrollable and the direction to search.
Future<void> revealJourneyControl(
  WidgetTester tester,
  Finder control, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = tester.binding.clock.now().add(timeout);
  do {
    await tester.pump(const Duration(milliseconds: 50));
    var reachable = false;
    final elements = control.evaluate().toList();
    if (elements.length == 1) {
      final route = ModalRoute.of(elements.single);
      if (route == null ||
          (route.isCurrent &&
              (route.animation == null ||
                  route.animation!.status == AnimationStatus.completed))) {
        if (control.hitTestable().evaluate().isEmpty) {
          await Scrollable.ensureVisible(elements.single, alignment: .5);
          await tester.pump();
        }
        reachable = control.hitTestable().evaluate().length == 1;
      }
    }
    final exception = tester.takeException();
    if (exception != null) throw exception;
    if (reachable) return;
  } while (tester.binding.clock.now().isBefore(deadline));
  throw TestFailure(
    'Control did not become reachable within $timeout: $control; '
    'matches=${control.evaluate().length}, '
    'viewport=${tester.view.physicalSize / tester.view.devicePixelRatio}, '
    'keyboardInset=${tester.view.viewInsets.bottom / tester.view.devicePixelRatio}',
  );
}

/// Dispatch exactly once, only after the target can receive the pointer.
Future<void> tapJourneyControl(WidgetTester tester, Finder control) async {
  await revealJourneyControl(tester, control);
  await tester.tap(control);
}

/// Reach a later transcript action with bounded touch drags. This intentionally
/// does not jump a ScrollPosition or call ensureVisible: recovery must work by
/// scrolling the visible conversation, including beside a nested form viewport.
Future<int> dragTranscriptToControl(WidgetTester tester, Finder control) =>
    dragViewportToControl(
      tester,
      find.byKey(const ValueKey('profile-transcript')),
      control,
    );

Future<int> dragViewportToControl(
  WidgetTester tester,
  Finder scrollable,
  Finder control,
) async {
  for (var attempt = 0; attempt <= 8; attempt++) {
    final viewport = tester.getRect(scrollable);
    if (control.hitTestable().evaluate().length == 1) {
      final bounds = tester.getRect(control);
      if (viewport.contains(bounds.topLeft) &&
          viewport.contains(bounds.bottomRight - const Offset(.1, .1))) {
        return attempt;
      }
    }
    if (attempt == 8) break;
    final bounds = control.evaluate().length == 1
        ? tester.getRect(control)
        : null;
    final distance = bounds == null
        ? -viewport.height * .65
        : bounds.top < viewport.top
        ? viewport.top - bounds.top
        : viewport.bottom - bounds.bottom;
    final movement = distance.clamp(-viewport.height, viewport.height);
    final gesture = await tester.startGesture(
      Offset(viewport.right - 8, viewport.center.dy),
    );
    // Cross the touch threshold first, then move by the remaining visible gap.
    // This is still a real drag; exact small viewports must not oscillate past
    // a 48dp target because every attempt moves by an arbitrary fixed fraction.
    // For a smaller correction, start away from the target so crossing the
    // threshold cannot first stretch content beyond its scroll boundary.
    final thresholdDirection = movement.abs() < kTouchSlop + 1
        ? -movement.sign
        : movement.sign;
    await gesture.moveBy(Offset(0, (kTouchSlop + 1) * thresholdDirection));
    await tester.pump();
    final movedViewport = tester.getRect(scrollable);
    final movedBounds = control.evaluate().length == 1
        ? tester.getRect(control)
        : null;
    final remaining = movedBounds == null
        ? movement
        : movedBounds.top < movedViewport.top
        ? movedViewport.top - movedBounds.top
        : movedViewport.bottom - movedBounds.bottom;
    await gesture.moveBy(
      Offset(0, remaining.clamp(-movedViewport.height, movedViewport.height)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(Offset.zero);
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final exception = tester.takeException();
    if (exception != null) throw exception;
  }
  throw TestFailure(
    'Action stayed unreachable after eight touch drags: $control; '
    'viewport=${tester.getRect(scrollable)}, '
    'target=${control.evaluate().length == 1 ? tester.getRect(control) : null}, '
    'size=${control.evaluate().length == 1 ? tester.getSize(control) : null}',
  );
}
