/// A local library store's upload outcome, including partial server failures.
typedef LibraryUploadResult = ({int pushed, int failed});

/// Uploads every library even when one store fails. Returning a failure count
/// prevents an unavailable server from being presented as "already synced".
Future<LibraryUploadResult> uploadLibraryStores(
  Iterable<Future<LibraryUploadResult> Function()> stores,
) async {
  var pushed = 0;
  var failed = 0;
  for (final upload in stores) {
    try {
      final result = await upload();
      pushed += result.pushed;
      failed += result.failed;
    } catch (_) {
      // Store contents and authentication details must not enter UI errors.
      failed++;
    }
  }
  return (pushed: pushed, failed: failed);
}
