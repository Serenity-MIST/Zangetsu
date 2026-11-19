import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Windows-only safety net for page keyboard shortcuts.
///
/// Page shortcuts (Home, Downloads, detail, search pages, player, reader)
/// only fire while focus sits inside the page's own Focus node. Several
/// ordinary actions leave focus on a bare FocusScope instead: a text field
/// giving up focus, a hidden tab dropping its focus, a focused widget being
/// removed (closing the Watch Together chat, a row rebuilding while the
/// window was in the background). Nothing moves focus back afterwards, so
/// every page key stays dead until the user clicks something focusable.
///
/// Pages register their key node here. [run] puts focus back on the newest
/// registered node that can take it whenever focus is lost (null, a bare
/// scope or the window's own fallback node). It never moves focus away from a
/// real widget (a text field, a button, a dialog), so it cannot steal input.
abstract final class DesktopFocusRepair {
  /// Registered page nodes, oldest first (the newest is tried first).
  static final List<FocusNode> _nodes = [];

  /// DesktopWindow's own app-key node. Focus resting there means no page has
  /// focus, so it is treated like a lost focus.
  static FocusNode? windowNode;

  // True while a post-frame [run] is already queued (debounce).
  static bool _scheduled = false;

  // New UI behaviour is gated on the target platform so phones never run it
  // and widget tests can switch it on.
  static bool get _enabled => defaultTargetPlatform == TargetPlatform.windows;

  /// Adds (or moves to newest) a page's key node.
  static void register(FocusNode node) {
    _nodes
      ..remove(node)
      ..add(node);
  }

  /// Removes a page's key node; call from the page's dispose.
  static void unregister(FocusNode node) => _nodes.remove(node);

  /// Read-only view for tests.
  @visibleForTesting
  static List<FocusNode> get registered => List.unmodifiable(_nodes);

  /// Clears all state between widget tests.
  @visibleForTesting
  static void debugReset() {
    _nodes.clear();
    windowNode = null;
    _scheduled = false;
  }

  /// Replacement for `FocusScope.of(context).unfocus()` (closing a keyboard
  /// / leaving a text field). Phone keeps exactly that call. On Windows that
  /// call parked focus on the route scope and wiped its history, killing the
  /// page keys; here only a focused text field is left, focus goes back to
  /// the node focused before it, and the repair covers the rest.
  static void dropFocus(BuildContext context) {
    if (!_enabled) {
      FocusScope.of(context).unfocus();
      return;
    }
    final primary = FocusManager.instance.primaryFocus;
    if (primary != null && _inTextField(primary)) {
      leaveTextField(primary);
      return;
    }
    schedule();
  }

  /// Leaves the focused text field [field] (Esc, a click outside, Enter):
  /// focus goes back to the node focused before it (the page node or a
  /// button), never into another text field, which would move the caret
  /// somewhere the user did not click and keep the page keys dead. A bare
  /// scope left behind is fixed by the repair.
  static void leaveTextField(FocusNode field) {
    // Not focused: nothing to leave (and the scope's history below would
    // point at whatever else holds focus).
    if (!field.hasFocus) return;
    final scope = field.enclosingScope;
    field.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);
    // unfocus() picked its target synchronously: the newest entry of the
    // scope's focus history, followed down through nested scopes.
    FocusNode? next = scope?.focusedChild;
    while (next is FocusScopeNode && next.focusedChild != null) {
      next = next.focusedChild;
    }
    if (next != null && !identical(next, field) && _inTextField(next)) {
      // An older text field would get the caret: rest on the scope instead
      // and let the repair hand focus to the page node.
      next.unfocus();
    }
    schedule();
  }

  // True when [node] belongs to a text field (EditableText or inside one).
  static bool _inTextField(FocusNode node) {
    final context = node.context;
    if (context == null) return false;
    return context.widget is EditableText ||
        context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  /// Whether the current primary focus is "lost": nothing focused, a bare
  /// scope that is not itself a registered page node, or the window node.
  static bool focusIsLost() {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null) return true;
    if (_nodes.contains(primary)) return false;
    if (identical(primary, windowNode)) return true;
    return primary is FocusScopeNode;
  }

  /// Queues one [run] after the next frame (focus changes settle during the
  /// frame, e.g. a hidden tab's ExcludeFocus drops its node while building).
  static void schedule() {
    if (!_enabled || _scheduled) return;
    _scheduled = true;
    final binding = SchedulerBinding.instance;
    binding.addPostFrameCallback((_) {
      _scheduled = false;
      run();
    });
    // Make sure a frame actually comes (e.g. right after an app resume).
    binding.ensureVisualUpdate();
  }

  /// Refocuses the newest usable page node if focus is lost. Returns the
  /// node it focused, or null when nothing needed (or could take) focus.
  static FocusNode? run() {
    if (!_enabled || !focusIsLost()) return null;
    for (final node in _nodes.reversed) {
      if (_usable(node)) {
        node.requestFocus();
        return node;
      }
    }
    return null;
  }

  // A node can take focus: still mounted, not inside a hidden tab
  // (IndexedStack wraps those in ExcludeFocus, so canRequestFocus is false)
  // and on the route the user is looking at (not covered by a dialog/page).
  static bool _usable(FocusNode node) {
    final context = node.context;
    if (context == null || !context.mounted) return false;
    if (!node.canRequestFocus) return false;
    final route = ModalRoute.of(context);
    return route?.isCurrent ?? true;
  }
}

/// Drop-in for `Focus(autofocus: ...)` around a page's key handler that
/// also registers its node with [DesktopFocusRepair], so a lost focus comes
/// back to this page. Builds exactly the same Focus otherwise.
class DesktopRepairFocus extends StatefulWidget {
  const DesktopRepairFocus({
    super.key,
    required this.child,
    this.focusNode,
    this.autofocus = false,
    this.skipTraversal,
    this.onKeyEvent,
    this.debugLabel,
  });

  final Widget child;

  /// Optional caller-owned node; one is created (and disposed) otherwise.
  final FocusNode? focusNode;
  final bool autofocus;
  final bool? skipTraversal;
  final FocusOnKeyEventCallback? onKeyEvent;
  final String? debugLabel;

  @override
  State<DesktopRepairFocus> createState() => _DesktopRepairFocusState();
}

class _DesktopRepairFocusState extends State<DesktopRepairFocus> {
  // Node created here when the caller passed none.
  FocusNode? _own;

  FocusNode get _node =>
      widget.focusNode ?? (_own ??= FocusNode(debugLabel: widget.debugLabel));

  @override
  void initState() {
    super.initState();
    DesktopFocusRepair.register(_node);
  }

  @override
  void didUpdateWidget(DesktopRepairFocus oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Keep the registration on whichever node is current.
    if (oldWidget.focusNode != widget.focusNode) {
      DesktopFocusRepair.unregister(oldWidget.focusNode ?? _own!);
      DesktopFocusRepair.register(_node);
    }
  }

  @override
  void dispose() {
    DesktopFocusRepair.unregister(_node);
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _node,
    autofocus: widget.autofocus,
    skipTraversal: widget.skipTraversal,
    onKeyEvent: widget.onKeyEvent,
    child: widget.child,
  );
}
