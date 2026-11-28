import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_module.dart';

/// Ensures ranking cannot send live-action titles to declared anime-only sources.
void main() {
  const pool = [
    (id: 'anikoto', name: 'Anikoto'),
    (id: 'mixed', name: 'Mixed'),
    (id: 'cine', name: 'CineStream'),
    (id: 'unknown', name: 'Unknown'),
  ];
  for (final kind in [ZKind.movie, ZKind.tv]) {
    test('$kind skips anime-only and keeps mixed and unknown sources', () {
      expect(
        automaticKindPool(
          pool,
          kind,
          anime: {'anikoto', 'mixed'},
          movies: {'mixed', 'cine'},
        ).map((s) => s.id),
        ['mixed', 'cine', 'unknown'],
      );
    });
  }
  test('anime searches retain their providers', () {
    expect(
      automaticKindPool(
        pool,
        ZKind.anime,
        anime: {'anikoto'},
        movies: {'cine'},
      ),
      pool,
    );
  });
}
