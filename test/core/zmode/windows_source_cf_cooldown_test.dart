// The pure Windows Cloudflare cooldown rule for JS sources (plan 1, P1):
// a source is skipped only after its OWN ask missed while a new challenge
// was recorded, only for 3 minutes, and a hit (or a cleared flag) lifts it.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_source_cf_cooldown.dart';
import 'package:watch_app/core/provider/cf_solve_needed.dart';

void main() {
  var now = DateTime(2026, 11, 22, 12);
  setUp(() {
    now = DateTime(2026, 11, 22, 12);
    DesktopSourceCfCooldown.clock = () => now;
    CfSolveNeeded.debugReset();
  });
  tearDown(() {
    DesktopSourceCfCooldown.clock = DateTime.now;
    CfSolveNeeded.debugReset();
  });

  test('only JS sources follow the rule', () {
    expect(DesktopSourceCfCooldown.isJsSource('animekai'), isTrue);
    for (final id in ['ani:1', 'cs:x', 'mihon:2', 'lnr:y']) {
      expect(DesktopSourceCfCooldown.isJsSource(id), isFalse, reason: id);
    }
  });

  test('a miss with no new challenge never starts the cooldown', () {
    final c = DesktopSourceCfCooldown()
      ..record('s', hit: false, revisionBefore: 3, revisionAfter: 3);
    expect(c.blocked('s', stillFlagged: true), isFalse);
  });

  test('a miss behind a fresh challenge blocks for 3 minutes only', () {
    final c = DesktopSourceCfCooldown()
      ..record('s', hit: false, revisionBefore: 3, revisionAfter: 4);
    expect(c.blocked('s', stillFlagged: true), isTrue);
    now = now.add(const Duration(minutes: 2, seconds: 59));
    expect(c.blocked('s', stillFlagged: true), isTrue);
    now = now.add(const Duration(seconds: 2));
    expect(c.blocked('s', stillFlagged: true), isFalse);
  });

  test('a hit clears the cooldown', () {
    final c = DesktopSourceCfCooldown()
      ..record('s', hit: false, revisionBefore: 0, revisionAfter: 1)
      ..record('s', hit: true, revisionBefore: 1, revisionAfter: 2);
    expect(c.blocked('s', stillFlagged: true), isFalse);
  });

  test('verifying (flag gone) lifts the skip at once', () {
    final c = DesktopSourceCfCooldown()
      ..record('s', hit: false, revisionBefore: 0, revisionAfter: 1);
    expect(c.blocked('s', stillFlagged: false), isFalse);
  });

  test('the one helper: phone and native sources read the plain flag', () {
    final c = DesktopSourceCfCooldown();
    CfSolveNeeded.needsSolve('h.test', 'https://h.test', sourceId: 'js');
    CfSolveNeeded.needsSolve('n.test', 'https://n.test', sourceId: 'cs:n');
    // Phone: flagged means skipped, as before.
    expect(desktopSkipForCloudflare('js', windows: false, cooldown: c), isTrue);
    // Windows native: unchanged too.
    expect(
      desktopSkipForCloudflare('cs:n', windows: true, cooldown: c),
      isTrue,
    );
    // Windows JS: an old flag alone does not skip.
    expect(desktopSkipForCloudflare('js', windows: true, cooldown: c), isFalse);
    c.record('js', hit: false, revisionBefore: 0, revisionAfter: 1);
    expect(desktopSkipForCloudflare('js', windows: true, cooldown: c), isTrue);
  });
}
