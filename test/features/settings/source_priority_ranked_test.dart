import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/features/settings/source_priority_screen.dart';

void main() {
  test('reordering a filtered movie pool retains hidden anime pins', () {
    expect(
      sourcePinsAfterReorder(
        visible: ['movie-b', 'movie-a', 'movie-c'],
        previous: ['anime-only', 'movie-a'],
        placedAt: 0,
      ),
      ['movie-b', 'anime-only'],
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
