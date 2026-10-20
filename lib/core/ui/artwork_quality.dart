/// Uses the CDN's original artwork when a desktop surface needs more pixels.
/// Only TMDB's documented image-size segment is replaced; arbitrary extension
/// URLs, signed query strings and source-specific filenames stay intact.
String desktopArtworkUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      uri.host != 'image.tmdb.org' ||
      !uri.path.startsWith('/t/p/'))
    return url;
  return uri
      .replace(
        path: uri.path.replaceFirst(
          RegExp(r'^/t/p/(?:w\d+|h\d+)/'),
          '/t/p/original/',
        ),
      )
      .toString();
}

/// Decodes for the actual painted width and display scale, with a small margin
/// for hover scaling. The cap bounds memory on ultrawide/high-DPI monitors.
int artworkDecodeWidth(
  double width,
  double devicePixelRatio, {
  int maximum = 3840,
}) => (width * devicePixelRatio * 1.1).ceil().clamp(64, maximum);
