import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../features/reader/desktop_reader_input.dart';
import '../ui/global_messenger.dart';
import 'desktop_player_input.dart';

/// Marks a subtree that handles the mouse Back side button itself (shell-6).
/// While it sits in the top route, the app-wide Back button handler in
/// DesktopWindow leaves the click alone, so the two never both act.
class DesktopMouseBackOwner extends StatelessWidget {
  const DesktopMouseBackOwner({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}

/// App-wide mouse Back button support (shell-6). A screen that already
/// handles the side button (the player pops itself, the reader turns pages)
/// receives the press first, because a Listener deep in the tree runs before
/// the one at the window root. This class lets the root handler tell whether
/// such a screen already acted, so Back never runs twice.
abstract final class DesktopMouseBack {
  /// Top route of the app navigator when the last pointer hit test ran,
  /// which is before any Listener sees the press.
  static Route<dynamic>? _routeAtHitTest;

  /// Current top route of the app navigator (null before it exists).
  static Route<dynamic>? topRoute() {
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) return null;
    Route<dynamic>? top;
    // popUntil checks the top route first and stops at once when the
    // predicate is true, so this reads the top route without popping.
    navigator.popUntil((route) {
      top = route;
      return true;
    });
    return top;
  }

  /// Called from the hit test, before the press reaches any screen.
  static void snapshot() => _routeAtHitTest = topRoute();

  /// True when the root handler must leave this Back press alone: a screen
  /// already changed the route for it, or the top route contains a widget
  /// that handles the side button itself.
  static bool handledElsewhere() {
    final top = topRoute();
    // The player popped (or replaced) its route in its own handler.
    if (_routeAtHitTest != null && !identical(top, _routeAtHitTest)) {
      return true;
    }
    if (top is! ModalRoute) return false;
    final context = top.subtreeContext;
    if (context == null) return false;
    return _containsOwner(context as Element);
  }

  /// Walks the top route's widgets for a screen that owns the Back button.
  /// Only runs on a Back press, so the walk's cost does not matter.
  static bool _containsOwner(Element root) {
    var found = false;
    void visit(Element element) {
      if (found) return;
      final widget = element.widget;
      if (widget is DesktopPlayerInput ||
          widget is DesktopReaderInput ||
          widget is DesktopMouseBackOwner) {
        found = true;
        return;
      }
      element.visitChildren(visit);
    }

    visit(root);
    return found;
  }

  /// True for a mouse press whose buttons include the Back side button.
  static bool isBackPress(PointerDownEvent event) =>
      event.kind == PointerDeviceKind.mouse &&
      event.buttons & kBackMouseButton != 0;
}

/// Pass-through box that records the top route whenever a pointer hit test
/// runs, i.e. before the press is delivered to any Listener (shell-6).
class DesktopMouseBackProbe extends SingleChildRenderObjectWidget {
  const DesktopMouseBackProbe({super.key, super.child, this.enabled = true});

  /// Off: the probe records nothing (non-Windows UI in tests).
  final bool enabled;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderDesktopMouseBackProbe(enabled);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderDesktopMouseBackProbe renderObject,
  ) {
    renderObject.enabled = enabled;
  }
}

/// Render object of [DesktopMouseBackProbe].
class RenderDesktopMouseBackProbe extends RenderProxyBox {
  RenderDesktopMouseBackProbe(this.enabled);
  bool enabled;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // Cheap (reads the last history entry); hover hit tests call it too.
    if (enabled) DesktopMouseBack.snapshot();
    return super.hitTest(result, position: position);
  }
}
