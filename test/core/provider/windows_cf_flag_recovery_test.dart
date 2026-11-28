// Windows: a Cloudflare-flagged host that answers normally again gets its
// Verify flag lifted (plan 1, P1 step 3). The decision is the pure
// desktopShouldClearCfFlag; provider_manager calls it, Windows-gated, after
// every JS fetch that was not a challenge.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_cf_flag_recovery.dart';
import 'package:watch_app/core/provider/cf_solve_needed.dart';

void main() {
  setUp(CfSolveNeeded.debugReset);
  tearDown(CfSolveNeeded.debugReset);

  // Decides for a fetch of [url] (default: the challenged page itself).
  bool decide(String host, int status, {String? url}) =>
      desktopShouldClearCfFlag(
        hostFlagged: CfSolveNeeded.hostFlagged(host),
        usesJsSolver: CfSolveNeeded.usesJsSolver(host),
        challenged: false,
        status: status,
        url: url ?? 'https://$host/x',
        challengeUrl: CfSolveNeeded.urlForHost(host),
      );

  test('a normal answer from a JS-flagged host clears its flag', () {
    CfSolveNeeded.needsSolve('a.test', 'https://a.test/x', sourceId: 'js');
    expect(decide('a.test', 200), isTrue);
    expect(decide('a.test', 302), isTrue);
    CfSolveNeeded.clear('a.test');
    expect(CfSolveNeeded.sourceFlagged('js'), isFalse);
  });

  test('a host that is not flagged is left alone', () {
    expect(decide('b.test', 200), isFalse);
  });

  test('errors and challenges do not count as "works again"', () {
    CfSolveNeeded.needsSolve('a.test', 'https://a.test/x', sourceId: 'js');
    expect(decide('a.test', 403), isFalse);
    expect(decide('a.test', 503), isFalse);
    expect(decide('a.test', 0), isFalse);
    expect(
      desktopShouldClearCfFlag(
        hostFlagged: true,
        usesJsSolver: true,
        challenged: true,
        status: 200,
        url: 'https://a.test/x',
        challengeUrl: 'https://a.test/x',
      ),
      isFalse,
    );
  });

  test('a host flagged by a native extension keeps its flag', () {
    // Its cookie jar is separate; a JS request getting through says
    // nothing about it.
    CfSolveNeeded.needsSolve('n.test', 'https://n.test', sourceId: 'ani:1');
    expect(decide('n.test', 200, url: 'https://n.test'), isFalse);
  });

  test('a 200 from another, unprotected path keeps the flag', () {
    // The site challenges only its search page; the episode page answering
    // must not hide the Verify offer for search.
    CfSolveNeeded.needsSolve(
      'a.test',
      'https://a.test/search?q=one',
      sourceId: 'js',
    );
    expect(decide('a.test', 200, url: 'https://a.test/episode/1'), isFalse);
    // The same page with a new query proves it answers again.
    expect(decide('a.test', 200, url: 'https://a.test/search?q=two'), isTrue);
    expect(decide('a.test', 200, url: 'https://a.test/search/'), isTrue);
  });

  test('same path check needs a recorded challenge url', () {
    expect(desktopSameCfPath('https://a.test/x', null), isFalse);
    expect(desktopSameCfPath('https://a.test/x', 'https://b.test/x'), isFalse);
    expect(desktopSameCfPath('https://a.test', 'https://a.test/'), isTrue);
  });
}
