import 'dart:io';

/// Parses server cooldown hints without persisting stream URLs or credentials.
/// Queue integration stores only the resulting host deadline on this device.
DateTime downloadRetryDeadline(String? retryAfter, DateTime now) {
  final raw = retryAfter?.trim() ?? '';
  if (RegExp(r'^\d+$').hasMatch(raw)) {
    final seconds = BigInt.tryParse(raw);
    if (seconds != null) {
      final ceiling = BigInt.from(8640000000000000);
      final deadline = BigInt.from(now.millisecondsSinceEpoch) + seconds * BigInt.from(1000);
      return DateTime.fromMillisecondsSinceEpoch(
          (deadline > ceiling ? ceiling : deadline).toInt(), isUtc: true);
    }
  }
  try {
    final deadline = HttpDate.parse(raw);
    return deadline.isAfter(now) ? deadline : now.toUtc();
  } catch (_) {
    return now.toUtc().add(const Duration(minutes: 1));
  }
}
