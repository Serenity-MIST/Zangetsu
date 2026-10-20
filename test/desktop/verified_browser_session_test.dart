import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/provider/cf_clearance_store.dart';
import 'package:watch_app/core/desktop/desktop_cloudflare.dart';
import 'package:watch_app/core/desktop/desktop_flaresolverr.dart';

/// Exercises persisted browser-session eligibility using isolated test data.
void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('verified-browser-');
    Hive.init(directory.path);
    await CfClearanceStore.init();
  });
  tearDown(() async {
    await DesktopFlareSolverr.close();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('redirected sessions never export cookies to unrelated domains', () {
    rememberVerifiedBrowserSession('https://reader.example/', {
      'verified': true,
      'url': 'https://login.example/',
      'userAgent': 'Browser UA',
      'cookies': [
        {'name': 'reader', 'value': 'one', 'domain': 'reader.example'},
        {'name': 'login', 'value': 'two', 'domain': 'login.example'},
        {'name': 'legacy', 'value': 'three'},
      ],
    });
    final restored = CfClearanceStore().restore();
    expect(restored['reader.example']?.cookie, 'reader=one; legacy=three');
    expect(restored['login.example']?.cookie, 'login=two');
  });

  test('an unfinished verification cannot register a session', () {
    rememberVerifiedBrowserSession('https://reader.example/', {
      'verified': false,
      'cookie': 'cf_clearance=stale',
    });
    expect(CfClearanceStore().restore(), isEmpty);
    expect(
      DesktopFlareSolverr.hasVerifiedUrl('https://reader.example/'),
      isFalse,
    );
  });

  test('a verified cookie-free session survives restarting storage', () async {
    CfClearanceStore().remember(
      'reader.example',
      '',
      'Browser UA',
      browserVerified: true,
    );
    await Hive.box(CfClearanceStore.boxName).close();
    await CfClearanceStore.init();
    expect(CfClearanceStore().browserVerifiedFor('reader.example'), isTrue);
    expect(CfClearanceStore().restore()['reader.example']?.cookie, '');
    expect(CfClearanceStore().browserVerifiedFor('other.example'), isFalse);
  });

  test('an empty cookie alone cannot grant browser access', () {
    CfClearanceStore().remember('reader.example', '', 'Browser UA');
    expect(CfClearanceStore().browserVerifiedFor('reader.example'), isFalse);
    expect(CfClearanceStore().restore(), isEmpty);
  });

  test('expired and future-dated verification cannot grant access', () async {
    final box = Hive.box(CfClearanceStore.boxName);
    for (final timestamp in [
      DateTime.now().subtract(const Duration(hours: 13)),
      DateTime.now().add(const Duration(hours: 1)),
    ]) {
      await box.put('reader.example', {
        'cookie': '',
        'browserVerified': true,
        'ts': timestamp.millisecondsSinceEpoch,
      });
      expect(CfClearanceStore().browserVerifiedFor('reader.example'), isFalse);
    }
  });
}
