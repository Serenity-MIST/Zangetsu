import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/reading/read_history.dart';
import 'package:watch_app/core/reading/reading_resume.dart';

/// A mobile history entry whose source adapter uses different chapter keys.
ReadEntry history({
  String source = 'mobile',
  String show = 'mal:42',
  String chapterId = 'mobile-100',
  String chapterUrl = '/mobile/100',
  double? number = 100,
  int pos = 12,
  int total = 40,
  int updated = 200,
  ProviderType type = ProviderType.manga,
}) => ReadEntry(
  sourceId: source,
  showId: show,
  title: 'A title',
  chapterId: chapterId,
  chapterUrl: chapterUrl,
  chapterNumber: number,
  pos: pos,
  total: total,
  updatedMs: updated,
  type: type,
);

const chapters = [
  Episode(id: 'desktop-99', title: '99', url: '/desktop/99', number: 99),
  Episode(id: 'desktop-100', title: '100', url: '/desktop/100', number: 100),
  Episode(id: 'desktop-101', title: '101', url: '/desktop/101', number: 101),
];

void main() {
  test('synced chapter number survives different mobile/PC keys', () {
    expect(readingHistoryTarget(chapters, entry: history()), (
      index: 1,
      hasResume: true,
    ));
  });
  test('completed chapter advances to the next real chapter', () {
    expect(readingHistoryTarget(chapters, entry: history(pos: 39)), (
      index: 2,
      hasResume: true,
    ));
  });
  test('missing chapter continues at the next numbered release', () {
    expect(readingHistoryTarget(chapters, entry: history(number: 99.5)), (
      index: 1,
      hasResume: true,
    ));
  });
  test('newest-first source lists still choose the nearest next chapter', () {
    final reversed = chapters.reversed.toList();
    expect(readingHistoryTarget(reversed, entry: history(number: 99.5)), (
      index: 1,
      hasResume: true,
    ));
    expect(readingHistoryTarget(reversed, entry: history(pos: 39)), (
      index: 0,
      hasResume: true,
    ));
    expect(readingHistoryTarget(reversed, completedChapters: 999), (
      index: 0,
      hasResume: true,
    ));
  });
  test('fractional chapters and alternate groups keep the selected group', () {
    const releases = [
      Episode(
        id: 'b101',
        title: '101',
        url: '/b101',
        number: 101,
        scanlator: 'B',
      ),
      Episode(
        id: 'a1005',
        title: '100.5',
        url: '/a1005',
        number: 100.5,
        scanlator: 'A',
      ),
      Episode(
        id: 'b1005',
        title: '100.5',
        url: '/b1005',
        number: 100.5,
        scanlator: 'B',
      ),
      Episode(
        id: 'a100',
        title: '100',
        url: '/a100',
        number: 100,
        scanlator: 'A',
      ),
    ];
    expect(
      readingHistoryTarget(
        releases,
        entry: history(chapterUrl: '/a100', chapterId: 'a100', pos: 39),
      ),
      (index: 1, hasResume: true),
    );
  });
  test('unknown progress does not invent a resume target', () {
    expect(readingHistoryTarget(chapters, entry: history(number: null)), (
      index: 0,
      hasResume: false,
    ));
  });
  test('tracker chapter count advances without local reading history', () {
    expect(readingHistoryTarget(chapters, completedChapters: 100), (
      index: 2,
      hasResume: true,
    ));
  });
  test('completed tracker count at end stays on the final chapter', () {
    expect(readingHistoryTarget(chapters, completedChapters: 999), (
      index: 2,
      hasResume: true,
    ));
  });
  test(
    'vertical manga near-end completion matches local ReadStore semantics',
    () {
      expect(
        readingHistoryTarget(chapters, entry: history(pos: 95, total: 100)),
        (index: 2, hasResume: true),
      );
    },
  );
  test('empty list is safe with synced progress', () {
    expect(readingHistoryTarget([], entry: history()), (
      index: 0,
      hasResume: false,
    ));
  });
  test('canonical title keeps newest history after switching sources', () {
    final older = history(source: 'desktop', updated: 100);
    final newer = history(updated: 300);
    expect(
      readingHistoryForTitle(
        [older, newer],
        sourceId: 'desktop',
        showId: 'mal:42',
        type: ProviderType.manga,
      ),
      same(newer),
    );
  });
  test('plain provider IDs never match another source', () {
    expect(
      readingHistoryForTitle(
        [history(show: '42')],
        sourceId: 'desktop',
        showId: '42',
        type: ProviderType.manga,
      ),
      isNull,
    );
  });
  test('manga and novel history cannot cross even with the same ID', () {
    expect(
      readingHistoryForTitle(
        [history(type: ProviderType.novel)],
        sourceId: 'mobile',
        showId: 'mal:42',
        type: ProviderType.manga,
      ),
      isNull,
    );
  });
  test('chapter URL wins over an adapter-reused chapter ID', () {
    expect(
      readingHistoryChapter(
        chapters,
        history(chapterId: 'desktop-99', chapterUrl: '/desktop/100'),
      ),
      1,
    );
  });
}
