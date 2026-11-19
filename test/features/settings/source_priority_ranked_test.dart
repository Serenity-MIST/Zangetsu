import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/features/settings/source_priority_screen.dart';

void main() {
  test('reordering a filtered movie pool retains hidden anime pins in place',
      () {
    // The hidden pin sat at the front; it stays there instead of being
    // appended after the visible pins (which demoted it on every edit).
    expect(
      sourcePinsAfterReorder(
        visible: ['movie-b', 'movie-a', 'movie-c'],
        previous: ['anime-only', 'movie-a'],
        placedAt: 0,
      ),
      ['anime-only', 'movie-b'],
    );
  });

  test('a hidden pin stays right after the visible pin it followed', () {
    expect(
      sourcePinsAfterReorder(
        visible: ['a', 'b', 'c'],
        previous: ['a', 'hidden', 'b'],
        placedAt: 1,
      ),
      ['a', 'hidden', 'b'],
    );
  });

  test('keepPinned never unpins the other pinned rows', () {
    // c moved to the top; a and b were pinned and stay pinned.
    expect(
      sourcePinsAfterReorder(
        visible: ['c', 'a', 'b', 'd'],
        previous: ['a', 'b'],
        placedAt: 0,
        keepPinned: true,
      ),
      ['c', 'a', 'b'],
    );
    // Without it (phone / TV) only the moved row is pinned, as before.
    expect(
      sourcePinsAfterReorder(
        visible: ['c', 'a', 'b', 'd'],
        previous: ['a', 'b'],
        placedAt: 0,
      ),
      ['c'],
    );
  });

  test('reordering the complete pool pins only through the moved row', () {
    expect(
      sourcePinsAfterReorder(
        visible: ['b', 'a', 'c'],
        previous: ['a', 'c'],
        placedAt: 1,
      ),
      ['b', 'a'],
    );
  });

  // Locks the copy rule the screen's `_reasonFor` delegates to: dead beats a
  // good history, an unused source says so, everything else states its play
  // count. Asserts against the real `reasonForSource` in lib/, not a copy
  // redefined in the test.
  test('a source with plays says so, an unused one says that instead', () {
    expect(
      reasonForSource(plays: 47, health: SourceHealth.ok),
      'played 47 times',
    );
    expect(
      reasonForSource(plays: 0, health: SourceHealth.ok),
      isNull,
      reason:
          'a source nobody has played gets no line at all — on a fresh '
          'install that was every row saying the same thing',
    );
    expect(
      reasonForSource(plays: 99, health: SourceHealth.dead),
      "hasn't worked recently",
      reason: 'dead beats a good history — it cannot play right now',
    );
  });
}
