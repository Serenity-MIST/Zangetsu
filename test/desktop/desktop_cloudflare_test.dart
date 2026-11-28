import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_cloudflare.dart';

void main() {
  test('WebView cookie expiry keeps valid cookies valid in the JVM', () {
    expect(browserCookieExpiryMillis(1792000000), 1792000000000);
    expect(browserCookieExpiryMillis(1792000000000), 1792000000000);
    expect(browserCookieExpiryMillis(-1), isNull);
    expect(browserCookieExpiryMillis(0), isNull);
    expect(browserCookieExpiryMillis(null), isNull);
  });
  test('accepts a completed site page without a clearance cookie', () {
    expect(
      verificationPageReady({
        'ready': true,
        'body': true,
        'title': 'Read Solo Leveling Manga Online',
        'host': 'www.natomanga.com',
        'text': 'Solo Leveling Chapter 200 Chapter 199 Author Updated',
      }),
      isTrue,
    );
  });

  test('rejects pages which are still showing a challenge', () {
    expect(
      verificationPageReady({
        'ready': true,
        'body': true,
        'title': 'Just a moment...',
        'host': 'www.natomanga.com',
        'text': 'Checking if the site connection is secure',
      }),
      isFalse,
    );
  });

  test('rejects incomplete and browser error pages', () {
    expect(
      verificationPageReady({
        'ready': false,
        'body': true,
        'title': 'NatoManga',
        'host': 'www.natomanga.com',
        'text': 'Loading',
      }),
      isFalse,
    );
    expect(
      verificationPageReady({
        'ready': true,
        'body': true,
        'title': "This site can't be reached",
        'host': 'www.natomanga.com',
        'text': 'Check your internet connection',
      }),
      isFalse,
    );
  });
}
