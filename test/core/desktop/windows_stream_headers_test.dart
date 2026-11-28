// Plan item R1: the Cloudflare cookie headers the Windows mpv player sends.
// Pure-function cases for enrichDesktopStreamHeaders, plus the platform gate
// on desktopStreamHeaders (phones get the headers back untouched).
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_stream_headers.dart';

void main() {
  const ua = 'Mozilla/5.0 (Windows NT 10.0) Solver/1';
  final store = <String, ({String cookie, String? ua})>{
    'example.com': (cookie: 'cf_clearance=abc', ua: ua),
  };

  test('exact host gets the cookie, the solving User-Agent and an Origin', () {
    final out = enrichDesktopStreamHeaders(
      'https://example.com/v/master.m3u8',
      {'Referer': 'https://embed.site.net/e/1'},
      store,
    )!;
    expect(out['Cookie'], 'cf_clearance=abc');
    expect(out['User-Agent'], ua);
    expect(out['Origin'], 'https://embed.site.net');
    expect(out['Referer'], 'https://embed.site.net/e/1');
  });

  test('a subdomain uses the parent entry, never the other way round', () {
    final sub = enrichDesktopStreamHeaders(
      'https://cdn.example.com/seg.ts',
      null,
      store,
    );
    expect(sub?['Cookie'], 'cf_clearance=abc');

    final parent = enrichDesktopStreamHeaders(
      'https://example.com/a.mp4',
      null,
      {'cdn.example.com': (cookie: 'cf_clearance=x', ua: ua)},
    );
    expect(parent, isNull, reason: 'parent host must not use a child cookie');

    final lookalike = enrichDesktopStreamHeaders(
      'https://badexample.com/a.mp4',
      null,
      store,
    );
    expect(lookalike, isNull, reason: 'suffix without a dot is another host');
  });

  test('never overwrites headers the source set (any letter case)', () {
    final input = {
      'user-agent': 'SourceUA',
      'Referer': 'https://ref.example/',
      'Origin': 'https://own.origin',
      'cookie': 'cf_clearance=mine; other=1',
    };
    final out = enrichDesktopStreamHeaders(
      'https://example.com/x.m3u8',
      input,
      store,
    );
    // The source already sends cf_clearance, so nothing is added at all.
    expect(out, same(input));

    final withOtherCookie = enrichDesktopStreamHeaders(
      'https://example.com/x.m3u8',
      {'user-agent': 'SourceUA', 'cookie': 'other=1'},
      store,
    )!;
    expect(withOtherCookie['cookie'], 'other=1; cf_clearance=abc');
    expect(withOtherCookie['user-agent'], 'SourceUA');
    expect(withOtherCookie.containsKey('User-Agent'), isFalse);
  });

  test('an empty-cookie ("browser verified") entry adds nothing', () {
    final input = {'Referer': 'https://r.example/'};
    final out = enrichDesktopStreamHeaders(
      'https://example.com/a.mp4',
      input,
      {'example.com': (cookie: '', ua: ua)},
    );
    expect(out, same(input));
  });

  test('no matching host, or a non-web link, leaves headers alone', () {
    final input = {'Referer': 'https://r.example/'};
    expect(
      enrichDesktopStreamHeaders('https://other.org/a.mp4', input, store),
      same(input),
    );
    expect(
      enrichDesktopStreamHeaders(r'C:\Videos\ep1.mp4', input, store),
      same(input),
    );
    expect(
      enrichDesktopStreamHeaders('file:///C:/Videos/ep1.mp4', null, store),
      isNull,
    );
    expect(
      enrichDesktopStreamHeaders('https://example.com/a', input, const {}),
      same(input),
    );
  });

  test('the most specific stored host wins', () {
    final out = enrichDesktopStreamHeaders(
      'https://cdn.example.com/a.mp4',
      null,
      {
        'example.com': (cookie: 'cf_clearance=parent', ua: 'P'),
        'cdn.example.com': (cookie: 'cf_clearance=child', ua: 'C'),
      },
    )!;
    expect(out['Cookie'], 'cf_clearance=child');
    expect(out['User-Agent'], 'C');
  });

  test('desktopStreamHeaders is a no-op off Windows', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final input = {'Referer': 'https://r.example/'};
    expect(desktopStreamHeaders('https://example.com/a', input), same(input));
  });

  test('desktopStreamHeaders on Windows with no store open adds nothing', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final input = {'Referer': 'https://r.example/'};
    expect(desktopStreamHeaders('https://example.com/a', input), same(input));
  });
}
