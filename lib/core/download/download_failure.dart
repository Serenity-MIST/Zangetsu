/// Detect an explicit HTTP rate limit, including legacy stored HTML responses.
bool isDownloadRateLimit(String? detail, {int? statusCode}) =>
    statusCode == 429 ||
    RegExp(r'\b429\s+(?:Too Many Requests|rate limit)', caseSensitive: false)
        .hasMatch(detail ?? '');

/// Keep server response documents out of download rows, including old records.
/// Classification uses the actual HTTP code when the transport supplies one.
String downloadFailureMessage(String? detail,
    {int? statusCode, String fallback = 'Download failed'}) {
  if (isDownloadRateLimit(detail, statusCode: statusCode)) {
    return 'Source is rate limiting downloads (429). Try again later.';
  }
  final value = detail?.trim() ?? '';
  if (value.isEmpty) return fallback;
  if (RegExp(r'<(?:!doctype|html|head|body|title)\b', caseSensitive: false)
      .hasMatch(value)) {
    return statusCode != null && statusCode > 0
        ? 'Source returned an error (HTTP $statusCode). Try again later.'
        : 'Source returned an error page. Try again later.';
  }
  final singleLine = value.replaceAll(RegExp(r'\s+'), ' ');
  return singleLine.length <= 240
      ? singleLine
      : '${singleLine.substring(0, 237)}...';
}
