// P2: the Windows "Switch source" recovery picker must not leave an empty
// hand-picked pin behind (it would dead-end every Play of the show).
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/features/detail/desktop_source_pick.dart';

/// Records what the picker asked of the matcher. [match] is what the chosen
/// source answers (null = the source does not have the title). Like the real
/// matcher, pinTitleToSource pins even on a miss.
class _FakeMatcher implements SourceMatcher {
  _FakeMatcher(this.match);

  final SourceMatch? match;
  final pins = <String, String>{};
  int clears = 0;

  @override
  Future<SourceMatch?> pinTitleToSource(
    ZCanonical c,
    String sourceId, {
    required String title,
    String? altTitle,
    List<String> metadataAliases = const [],
    int? malId,
  }) async {
    pins[c.key] = sourceId;
    return match;
  }

  @override
  Future<void> clearTitlePin(ZCanonical c) async {
    clears++;
    pins.remove(c.key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _show = ZCanonical(ZKind.anime, 'mal:59978');

void main() {
  test('a pick whose source lacks the title leaves no pin (Auto Resolve)',
      () async {
    final matcher = _FakeMatcher(null);
    final m = await desktopPinTitleOrStayOnAuto(
      matcher,
      _show,
      'empty-source',
      title: 'Frieren',
    );
    expect(m, isNull);
    expect(matcher.clears, 1);
    expect(matcher.pins, isEmpty);
  });

  test('a pick whose source has the title stays pinned to this show',
      () async {
    const found = SourceMatch(
      sourceId: 'good-source',
      showUrl: 'https://example.test/frieren',
      showId: 'frieren',
      showTitle: 'Frieren',
      pinned: true,
    );
    final matcher = _FakeMatcher(found);
    final m = await desktopPinTitleOrStayOnAuto(
      matcher,
      _show,
      'good-source',
      title: 'Frieren',
    );
    expect(m, same(found));
    expect(matcher.clears, 0);
    expect(matcher.pins, {_show.key: 'good-source'});
  });
}
