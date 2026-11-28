import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// App-wide route observer so a widget can tell when another screen is pushed
/// over it. The detail screen subscribes through [RouteAware] to pause its hero
/// trailer while the player (or another title) is on top — so a muted trailer
/// isn't left decoding video behind whatever the user is actually looking at —
/// and resume it when they come back.
///
/// The home banner uses it the same way, to stop advancing while covered.
///
/// On Windows it also dismisses every open hover tooltip whenever a route is
/// pushed, popped, replaced or removed (see [_AppRouteObserver]).
final RouteObserver<PageRoute<dynamic>> appRouteObserver = _AppRouteObserver();

/// [RouteObserver] that reports a removed route as a pop and, on Windows,
/// fades out all open tooltips on every route change.
///
/// Why the tooltips: a tooltip label lives in the Overlay and fades out on the
/// ticker of the page that owns it. When a route is pushed while the label is
/// showing (e.g. hovering Profile > Settings and clicking it), the covered page
/// goes offstage, its tickers stop, and the label froze half-faded on top of
/// the new page. Starting the fade at the moment of the push lets it finish
/// while the old page is still on screen and ticking during the transition.
/// Off Windows the tooltip part does nothing.
class _AppRouteObserver extends RouteObserver<PageRoute<dynamic>> {
  /// Fades out every open tooltip (Windows only).
  void _dismissTooltips() {
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    RawTooltip.dismissAllToolTips();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _dismissTooltips();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _dismissTooltips();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _dismissTooltips();
  }

  /// The player leaves the stack with `removeRoute` when it minimizes into the
  /// mini player. That uncovers the screen below exactly like a pop does, but
  /// the stock observer only reports pops, so the home banner stayed paused
  /// until the next real navigation.
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    if (route is PageRoute<dynamic> && previousRoute is PageRoute<dynamic>) {
      didPop(route, previousRoute);
    } else {
      _dismissTooltips();
    }
  }
}
