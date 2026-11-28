import 'package:flutter/scheduler.dart';

/// The window's lifecycle state as a word for log lines ("resumed",
/// "inactive", "hidden", ...), so a slow or failed source search in the log
/// says whether the window was in front at the time.
///
/// "unknown" before the app's bindings exist (plain unit tests).
String lifecycleLabel() {
  try {
    return SchedulerBinding.instance.lifecycleState?.name ?? 'unknown';
  } catch (_) {
    return 'unknown';
  }
}
