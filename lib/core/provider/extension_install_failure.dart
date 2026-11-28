import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import '../../l10n/l10n.dart';

/// Download progress of an extension install: [received] bytes of [total]
/// (total is -1 or 0 when the server sends no length).
typedef ExtensionInstallProgress = void Function(int received, int total);

/// Why an Aniyomi / Mihon extension install failed, in two forms (src-2 A):
/// a short readable [reason] for the row / snackbar, and the raw [details]
/// for the 'Copy details' action so a bug report keeps the real error.
class ExtensionInstallFailure implements Exception {
  const ExtensionInstallFailure(
    this.reason, {
    required this.details,
    this.cancelled = false,
  });

  /// Short user-facing sentence, plain English (moved to l10n later).
  final String reason;

  /// The original error text (exception + message), for copying.
  final String details;

  /// True when the user pressed Cancel; callers stay quiet then.
  final bool cancelled;

  /// The extension installed, but no source from its package registered.
  factory ExtensionInstallFailure.noSource(String pkg) =>
      ExtensionInstallFailure(
        appL10n.installFailNoSource,
        details: 'listSources returned no source for $pkg',
      );

  /// Maps any install error onto a readable reason. Unknown errors keep a
  /// generic reason but never lose their text: it stays in [details].
  factory ExtensionInstallFailure.from(Object error) {
    if (error is ExtensionInstallFailure) return error;
    final details = _describe(error);
    if (error is DioException) {
      if (error.type == DioExceptionType.cancel) {
        return ExtensionInstallFailure(
          appL10n.downloadCancelled,
          details: details,
          cancelled: true,
        );
      }
      final status = error.response?.statusCode;
      // Shown in the install error row; appL10n because there is no context.
      final l10n = appL10n;
      final reason = switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.receiveTimeout ||
        DioExceptionType.sendTimeout =>
          l10n.installFailTimedOut,
        DioExceptionType.connectionError =>
          l10n.installFailBlocked,
        DioExceptionType.badCertificate =>
          l10n.installFailCertificate,
        DioExceptionType.badResponse when status == 404 =>
          l10n.installFailNotFound,
        DioExceptionType.badResponse when status == 403 || status == 429 =>
          l10n.installFailRefused('$status'),
        DioExceptionType.badResponse =>
          l10n.installFailServerError('${status ?? '?'}'),
        _ => l10n.downloadFailed,
      };
      return ExtensionInstallFailure(reason, details: details);
    }
    if (error is PlatformException) {
      final text = '${error.code} ${error.message ?? ''}'.toLowerCase();
      if (error.code == 'DESKTOP_RUNTIME' || text.contains('engine')) {
        return ExtensionInstallFailure(
          appL10n.installFailEngineNotRunning,
          details: details,
        );
      }
      if (text.contains('version') || text.contains('lib ')) {
        return ExtensionInstallFailure(
          appL10n.installFailNewerApp,
          details: details,
        );
      }
      if (error.code == 'SOURCE_TIMEOUT') {
        return ExtensionInstallFailure(
          appL10n.installFailEngineSlow,
          details: details,
        );
      }
      return ExtensionInstallFailure(
        appL10n.installFailNotLoaded,
        details: details,
      );
    }
    if (error is MissingPluginException) {
      return ExtensionInstallFailure(
        appL10n.installFailEngineNotRunning,
        details: details,
      );
    }
    if (error is FileSystemException) {
      return ExtensionInstallFailure(
        appL10n.installFailDisk,
        details: details,
      );
    }
    if (error is SocketException || error is HttpException) {
      return ExtensionInstallFailure(
        appL10n.installFailBlocked,
        details: details,
      );
    }
    return ExtensionInstallFailure(
      appL10n.installFailedPlain,
      details: details,
    );
  }

  /// Full text of [error]; Dio and platform errors carry more than toString.
  static String _describe(Object error) {
    if (error is DioException) {
      return [
        'DioException ${error.type.name}',
        if (error.response?.statusCode != null)
          'HTTP ${error.response!.statusCode}',
        error.requestOptions.uri.toString(),
        if (error.message != null) error.message!,
        if (error.error != null) '${error.error}',
      ].join(' | ');
    }
    if (error is PlatformException) {
      return [
        'PlatformException ${error.code}',
        if (error.message != null) error.message!,
        if (error.details != null) '${error.details}',
      ].join(' | ');
    }
    return '$error';
  }

  @override
  String toString() => reason;
}
