import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'extension_runtime.dart';
import '../../l10n/l10n.dart';

/// src-11: helpers for the "Source timed out - Retry" state. The Windows
/// extension engine now gives each action its own limit (covers 15s, search
/// 30s, episode lists 45s, others 60s) and fails with
/// [DesktopExtensionRuntime.timeoutCode]; screens use these to tell that
/// apart from a generic failure.

/// True when [error] (or the text a provider wrapped it into) is an
/// extension-engine time-out.
bool isSourceTimeout(Object? error) {
  if (error == null) return false;
  if (error is TimeoutException) return true;
  if (error is PlatformException) {
    return error.code == DesktopExtensionRuntime.timeoutCode;
  }
  // Providers often rethrow as a string/Exception carrying only the code or
  // the message; match either text.
  final text = '$error';
  return text.contains(DesktopExtensionRuntime.timeoutCode) ||
      text.contains('Source timed out');
}

/// User-facing message for a load failure: the time-out text when it timed
/// out, else [fallback].
String sourceFailureMessage(Object? error, String fallback) =>
    isSourceTimeout(error)
    ? appL10n.sourceTimedOutSlow
    : fallback;

/// Compact "Source timed out" panel with a Retry button, for the places a
/// source's results, details or episode list load.
class SourceTimedOutState extends StatelessWidget {
  const SourceTimedOutState({super.key, required this.onRetry, this.message});

  /// Runs the same load again.
  final VoidCallback onRetry;

  /// Optional override of the default explanation.
  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      key: const ValueKey('source-timed-out'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.hourglass_disabled_rounded,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              context.l10n.sourceTimedOutTitle,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              message ??
                  context.l10n.sourceTookTooLong,
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(context.l10n.retry),
            ),
          ],
        ),
      ),
    );
  }
}
