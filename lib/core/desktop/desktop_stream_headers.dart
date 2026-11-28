import 'package:flutter/foundation.dart';

import '../provider/cf_clearance_store.dart';

/// Windows only: adds the saved Cloudflare clearance to the headers mpv (and
/// the player's own subtitle / playlist fetches) send for a stream link.
///
/// Why: the scraper fetched the page with a solved Cloudflare cookie, but mpv
/// fetches the video itself and used to send only the source's own headers.
/// A Cloudflare-fronted video host then answers 403 to mpv even though the
/// scrape worked. The phone fixes the same gap in `PluginHost.enrichLinkHeaders`;
/// this is the Windows copy of that rule, kept purely additive:
///
///  * A header the source already set is never replaced (names are compared
///    without case, so `user-agent` and `User-Agent` are the same header).
///  * The cookie is attached only when the link's host is the stored host or
///    a subdomain of it (`cdn.example.com` uses `example.com`'s entry, never
///    the other way round). When several entries fit, the most specific wins.
///  * When a cookie is attached, the User-Agent that solved it goes with it
///    (only if the source set none, because Cloudflare ties the cookie to that
///    exact browser), and an Origin built from the Referer is added (only if
///    the source set none), as the phone does.
///  * An entry with an empty cookie ("browser verified" without a
///    cf_clearance cookie) adds nothing at all.
///  * No matching entry: the headers come back exactly as they went in.
///
/// [clearances] is the map [CfClearanceStore.restore] returns
/// (host -> cookie + user agent). Returns [headers] itself (possibly null)
/// when nothing was added, so callers keep today's behaviour untouched.
Map<String, String>? enrichDesktopStreamHeaders(
  String url,
  Map<String, String>? headers,
  Map<String, ({String cookie, String? ua})> clearances,
) {
  if (clearances.isEmpty) return headers;
  final uri = Uri.tryParse(url);
  final scheme = uri?.scheme.toLowerCase() ?? '';
  // Only web links carry cookies; local files and loopback proxies do not.
  if (uri == null || (scheme != 'http' && scheme != 'https')) return headers;
  final host = uri.host.toLowerCase();
  if (host.isEmpty) return headers;

  // Pick the most specific stored host that this link belongs to.
  String? bestHost;
  ({String cookie, String? ua})? best;
  clearances.forEach((stored, entry) {
    final s = stored.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    if (s.isEmpty) return;
    final fits = host == s || host.endsWith('.$s');
    if (!fits) return;
    if (bestHost == null || s.length > bestHost!.length) {
      bestHost = s;
      best = entry;
    }
  });
  final entry = best;
  // Nothing stored for this host, or a "browser verified" entry with no
  // cookie: leave the headers alone.
  if (entry == null || entry.cookie.trim().isEmpty) return headers;

  final out = <String, String>{...?headers};
  String? keyOf(String name) {
    final lower = name.toLowerCase();
    for (final k in out.keys) {
      if (k.toLowerCase() == lower) return k;
    }
    return null;
  }

  // Cookie: add the stored pairs the source did not already send. A cookie
  // the source set keeps its own value (never overwritten).
  final cookieKey = keyOf('Cookie');
  final existing = cookieKey == null ? '' : out[cookieKey]!.trim();
  final existingNames = <String>{
    for (final part in existing.split(';'))
      if (part.contains('=')) part.substring(0, part.indexOf('=')).trim(),
  };
  final added = <String>[
    for (final part in entry.cookie.split(';'))
      if (part.contains('=') &&
          !existingNames.contains(part.substring(0, part.indexOf('=')).trim()))
        part.trim(),
  ];
  if (added.isEmpty) return headers; // the source already sends all of them
  final trimmedExisting = existing.replaceFirst(RegExp(r'[;\s]+$'), '');
  out[cookieKey ?? 'Cookie'] = trimmedExisting.isEmpty
      ? added.join('; ')
      : '$trimmedExisting; ${added.join('; ')}';

  // User-Agent: the cookie only works with the browser that earned it.
  final ua = entry.ua;
  if (ua != null && ua.isNotEmpty && keyOf('User-Agent') == null) {
    out['User-Agent'] = ua;
  }

  // Origin from the Referer, as the phone adds it for the same links.
  final refererKey = keyOf('Referer');
  if (refererKey != null && keyOf('Origin') == null) {
    final ref = Uri.tryParse(out[refererKey]!);
    if (ref != null && ref.scheme.isNotEmpty && ref.host.isNotEmpty) {
      out['Origin'] = '${ref.scheme}://${ref.host}${ref.hasPort ? ':${ref.port}' : ''}';
    }
  }
  return out;
}

/// The same as [enrichDesktopStreamHeaders], reading the saved clearances.
///
/// Only does anything on Windows; every other platform gets [headers] back
/// unchanged. Never throws: a store that is not open (tests, early boot)
/// simply adds nothing.
Map<String, String>? desktopStreamHeaders(
  String url,
  Map<String, String>? headers,
) {
  if (defaultTargetPlatform != TargetPlatform.windows) return headers;
  try {
    return enrichDesktopStreamHeaders(
      url,
      headers,
      CfClearanceStore().restore(),
    );
  } catch (_) {
    return headers;
  }
}
