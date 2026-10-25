/// Thrown when the JS runtime or a provider call fails.
class ProviderException implements Exception {
  ProviderException(this.message);
  final String message;
  @override
  String toString() => 'ProviderException: $message';
}

/// Thrown when the embedded QuickJS runtime rejects an eval or a call.
class JsRuntimeException implements Exception {
  JsRuntimeException(this.message);
  final String message;
  @override
  String toString() => 'JsRuntimeException: $message';
}

/// Thrown when a source is blocked by a Cloudflare challenge the headless
/// solver couldn't pass (an interactive Turnstile — Cloudflare serves these to
/// networks it doesn't trust, so a hidden WebView with nobody to click it can
/// never get through). [url] is the page to open in the visible WebView solve.
///
/// Native extension bridges and the Mangayomi worker report challenges in
/// different ways; providers normalize them to this so the UI can offer a
/// "Solve Cloudflare" action instead of a generic source error. The visible
/// WebView stores its clearance cookie for later source and media requests.
class CloudflareRequiredException implements Exception {
  const CloudflareRequiredException(this.url);

  /// The page URL to load in the solve WebView.
  final String url;

  @override
  String toString() => 'CloudflareRequiredException($url)';
}

/// Thrown when a network download (provider/extractor JS, manifest) fails.
class NetworkException implements Exception {
  NetworkException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'NetworkException($statusCode): $message';
}
