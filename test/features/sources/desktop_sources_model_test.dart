// Pure tests for the Windows Sources manager's model: chip / query
// filtering, pin order, disabled sources kept, and the label helpers.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/features/sources/desktop_source_popular_row.dart';
import 'package:watch_app/features/sources/desktop_sources_model.dart';

/// Shorthand for a source entry.
DesktopSourceEntry _e(
  String id,
  String name,
  DesktopSourceKind kind, {
  DesktopEcosystem eco = DesktopEcosystem.aniyomi,
  String lang = 'en',
  bool enabled = true,
}) => DesktopSourceEntry(
  id: id,
  name: name,
  ecosystem: eco,
  kind: kind,
  lang: lang,
  enabled: enabled,
);

void main() {
  final entries = [
    _e('ani:1', 'Anikoto', DesktopSourceKind.streaming),
    _e('ani:2', 'AnimeKai', DesktopSourceKind.streaming, lang: 'es'),
    _e(
      'cs:mb',
      'MovieBox',
      DesktopSourceKind.streaming,
      eco: DesktopEcosystem.cloudstream,
      lang: 'all',
    ),
    _e('mihon:9', 'MangaDex', DesktopSourceKind.manga, eco: DesktopEcosystem.mihon),
    _e(
      'lnr:x',
      'NovelBin',
      DesktopSourceKind.novel,
      eco: DesktopEcosystem.lnreader,
      lang: 'English',
    ),
    _e('zoff', 'Zeta Off', DesktopSourceKind.streaming,
        eco: DesktopEcosystem.zangetsu, enabled: false),
  ];

  group('filterDesktopSources', () {
    test('All keeps every source, sorted by name, disabled included', () {
      final out = filterDesktopSources(entries);
      expect(out.map((e) => e.name), [
        'Anikoto',
        'AnimeKai',
        'MangaDex',
        'MovieBox',
        'NovelBin',
        'Zeta Off',
      ]);
    });

    test('kind chips narrow to their bucket', () {
      expect(
        filterDesktopSources(entries, kind: DesktopSourceKind.manga)
            .map((e) => e.id),
        ['mihon:9'],
      );
      expect(
        filterDesktopSources(entries, kind: DesktopSourceKind.novel)
            .map((e) => e.id),
        ['lnr:x'],
      );
      expect(
        filterDesktopSources(entries, kind: DesktopSourceKind.streaming),
        hasLength(4),
      );
    });

    test('query matches name, ecosystem and an exact language code', () {
      expect(
        filterDesktopSources(entries, query: 'kai').map((e) => e.id),
        ['ani:2'],
      );
      expect(
        filterDesktopSources(entries, query: 'cloudstream').map((e) => e.id),
        ['cs:mb'],
      );
      expect(
        filterDesktopSources(entries, query: 'es').map((e) => e.id),
        ['ani:2'],
      );
    });

    test('pinned sources come first, in pin order', () {
      final out = filterDesktopSources(
        entries,
        pinned: const ['lnr:x', 'cs:mb'],
      );
      expect(out.take(2).map((e) => e.id), ['lnr:x', 'cs:mb']);
      expect(out.skip(2).first.name, 'Anikoto');
    });

    test('duplicate ids (CloudStream mixed providers) are listed once', () {
      final dup = [...entries, entries[2]];
      expect(
        filterDesktopSources(dup).where((e) => e.id == 'cs:mb'),
        hasLength(1),
      );
    });
  });

  group('labels', () {
    test('language tags and names', () {
      expect(desktopLangTag('en'), 'EN');
      expect(desktopLangTag('all'), 'ALL');
      expect(desktopLangTag('English'), 'English');
      expect(desktopLangTag('Русский'), 'Русский');
      expect(desktopLangName('all'), 'All languages');
      expect(desktopLangName('en'), 'English');
    });

    test('row subtitle is "Ecosystem · LANG"', () {
      expect(desktopSourceSubtitle(entries[0]), 'Aniyomi · EN');
    });

    test('health line parts omit unknown status and add Disabled', () {
      const e = DesktopSourceEntry(
        id: 'ani:1',
        name: 'Anikoto',
        ecosystem: DesktopEcosystem.aniyomi,
        kind: DesktopSourceKind.streaming,
        lang: 'en',
        version: '14',
        enabled: false,
      );
      expect(desktopHealthParts(e), [
        'Disabled',
        'Aniyomi',
        'v14',
        'English',
      ]);
      expect(
        desktopHealthParts(
          e,
          statusWord: desktopHealthWord(SourceHealth.ok),
        ).first,
        'Working',
      );
      expect(desktopHealthWord(null), isNull);
      expect(desktopHealthWord(SourceHealth.dead), 'Not responding');
    });

    test('footer line and relative day', () {
      const e = DesktopSourceEntry(
        id: 'x',
        name: 'X',
        ecosystem: DesktopEcosystem.cloudstream,
        kind: DesktopSourceKind.streaming,
        repoName: 'CNC Repo',
        contentLabel: 'Anime',
      );
      final now = DateTime(2026, 5, 10, 12);
      expect(
        desktopFooterLine(e, checkedAt: DateTime(2026, 5, 10, 1), now: now),
        'Repository: CNC Repo  ·  Last checked: today  ·  Content: Anime',
      );
      expect(desktopFooterLine(e), 'Repository: CNC Repo  ·  Content: Anime');
      expect(desktopRelativeDay(DateTime(2026, 5, 9), now), 'yesterday');
      expect(desktopRelativeDay(DateTime(2026, 5, 7), now), '3 days ago');
    });

    test('repo names and subtitles', () {
      expect(
        desktopRepoNameFromUrl(
          'https://raw.githubusercontent.com/owner/repo/main/index.min.json',
        ),
        'owner/repo',
      );
      expect(
        desktopRepoNameFromUrl('https://cdn.jsdelivr.net/gh/o/r@main/x.json'),
        'o/r',
      );
      expect(desktopRepoNameFromUrl('https://example.com/a.json'), 'example.com');
      expect(
        desktopRepoSubtitle(
          const DesktopRepoEntry(
            ecosystem: DesktopEcosystem.cloudstream,
            url: 'u',
            name: 'CNC Repo',
            sourceCount: 1,
          ),
        ),
        'CloudStream · 1 source',
      );
    });
  });

  test('pickPopularSection prefers a non-empty "Popular" section', () {
    MediaItem item(String t) =>
        MediaItem(
          id: t,
          title: t,
          url: '/$t',
          type: ProviderType.anime,
          sourceId: 's',
        );
    final sections = [
      const HomeSection(title: 'Latest', items: []),
      HomeSection(title: 'Recent', items: [item('a')]),
      HomeSection(title: 'Most Popular', items: [item('b')]),
    ];
    expect(pickPopularSection(sections)!.title, 'Most Popular');
    expect(pickPopularSection(sections.take(2).toList())!.title, 'Recent');
    expect(pickPopularSection(const []), isNull);
  });
}
