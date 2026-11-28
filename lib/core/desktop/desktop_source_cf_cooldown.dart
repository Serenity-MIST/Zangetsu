import 'package:flutter/foundation.dart';

import '../provider/cf_solve_needed.dart';

/// Windows only: a short, resolver-owned "skip for Cloudflare" rule for JS
/// sources.
///
/// Why: on Windows any JS fetch that looks like a Cloudflare challenge flags
/// its host in [CfSolveNeeded], and that flag never expires on its own. The
/// playback sweeps used to skip every flagged source, so ONE challenged side
/// request (an embed or extractor host) took the source out of every sweep
/// until the app restarted.
///
/// The flag itself stays (it drives the Verify banner). What changes is how
/// the sweeps read it for JS sources on Windows: a source is skipped only when
/// its OWN last ask missed while a new challenge was recorded during that ask,
/// and only for [cooldown]. A hit clears it. Native sources (`ani:`, `cs:`,
/// `mihon:`, `lnr:`) and phone/TV keep reading the plain flag.
class DesktopSourceCfCooldown {
  /// How long a source that just missed behind a fresh challenge is skipped.
  static const Duration cooldown = Duration(minutes: 3);

  /// The clock, so tests can step past [cooldown] without waiting.
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  /// sourceId -> the moment its skip ends.
  final Map<String, DateTime> _until = {};

  /// True for sources whose requests go through the JS provider runtime
  /// (the only ones this rule covers). Same prefixes as
  /// [CfSolveNeeded.usesJsSolver].
  static bool isJsSource(String sourceId) =>
      !const ['ani:', 'cs:', 'mihon:', 'lnr:'].any(sourceId.startsWith);

  /// Records how one ask of [sourceId] ended.
  ///
  /// [revisionBefore] / [revisionAfter] are [CfSolveNeeded.sourceRevision]
  /// read when the ask started and when it finished: a change means this
  /// source reported a new challenge during the ask.
  void record(
    String sourceId, {
    required bool hit,
    required int revisionBefore,
    required int revisionAfter,
  }) {
    if (hit) {
      // It works again: no reason to skip it any more.
      _until.remove(sourceId);
      return;
    }
    if (revisionAfter != revisionBefore) {
      _until[sourceId] = clock().add(cooldown);
    }
  }

  /// True while [sourceId] is inside its cooldown. [stillFlagged] is whether
  /// the Verify flag is still set for it: once the user verified (the flag is
  /// gone), the skip lifts at once instead of waiting the cooldown out.
  bool blocked(String sourceId, {required bool stillFlagged}) {
    final until = _until[sourceId];
    if (until == null) return false;
    if (!stillFlagged || !clock().isBefore(until)) {
      _until.remove(sourceId);
      return false;
    }
    return true;
  }
}

/// The one "skip this source for Cloudflare?" rule every playback call site
/// uses (progressive sweep, full sweep, probe list, download list).
///
/// On Windows, JS sources follow [DesktopSourceCfCooldown]; everything else
/// (native sources, and every source on phone and TV) is skipped exactly when
/// [CfSolveNeeded.sourceFlagged] says so, as before.
bool desktopSkipForCloudflare(
  String sourceId, {
  required bool windows,
  required DesktopSourceCfCooldown cooldown,
}) {
  final flagged = CfSolveNeeded.sourceFlagged(sourceId);
  if (!windows || !DesktopSourceCfCooldown.isJsSource(sourceId)) return flagged;
  return cooldown.blocked(sourceId, stillFlagged: flagged);
}
