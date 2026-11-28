/// Windows only: decides when a JS fetch proves a Cloudflare-flagged host
/// works again, so its Verify flag can be lifted.
///
/// Why: the flag in `CfSolveNeeded` never expires on its own, so the Verify
/// banner kept nagging about a host whose later requests were answering
/// normally. A real answer (2xx/3xx, not a challenge page) from that host
/// is proof it is reachable again.
///
/// Deliberately narrow:
/// - only hosts flagged by a JS source ([usesJsSolver]); a native extension
///   (Aniyomi, Mihon, CloudStream, LNReader) keeps its own cookie jar, so a
///   JS request getting through says nothing about it;
/// - only 2xx/3xx answers; a plain 403 or 5xx that our challenge check did
///   not recognise is not taken as "works again";
/// - only when the answer came from the same page path that was challenged
///   ([url] vs [challengeUrl]). Some sites protect only some paths (say the
///   search page) and leave others open; a 200 from an open path must not
///   hide the Verify offer for the path that is still blocked.
bool desktopShouldClearCfFlag({
  required bool hostFlagged,
  required bool usesJsSolver,
  required bool challenged,
  required int status,
  required String url,
  required String? challengeUrl,
}) =>
    hostFlagged &&
    usesJsSolver &&
    !challenged &&
    status >= 200 &&
    status < 400 &&
    desktopSameCfPath(url, challengeUrl);

/// True when [url] and [challengeUrl] point at the same page path on the
/// same host (the query string may differ: a new search term on the same
/// search page still proves that page answers). A missing or unreadable
/// challenge url gives false, so nothing is cleared on a guess.
bool desktopSameCfPath(String url, String? challengeUrl) {
  if (challengeUrl == null) return false;
  final a = Uri.tryParse(url);
  final b = Uri.tryParse(challengeUrl);
  if (a == null || b == null) return false;
  // Trailing slashes are ignored so "/search" and "/search/" match.
  String norm(String p) =>
      p.length > 1 && p.endsWith('/') ? p.substring(0, p.length - 1) : p;
  return a.host.toLowerCase() == b.host.toLowerCase() &&
      norm(a.path.isEmpty ? '/' : a.path) == norm(b.path.isEmpty ? '/' : b.path);
}
