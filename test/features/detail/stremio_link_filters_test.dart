// show-9: rules behind the Windows Stremio link filters.
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/stremio/stremio_link_session.dart';
import 'package:watch_app/core/stremio/stremio_ref.dart';
import 'package:watch_app/features/detail/stremio_link_filters.dart';
import 'package:zangetsu_source_bridge/stremio.dart';

const _ref = StremioRef(
  installationId: 'addon',
  type: 'movie',
  itemId: 'tt1',
  videoId: 'tt1',
);

// Builds a direct link with the given text and size.
StremioLinkChoice _link(
  String name, {
  String? description,
  String? fileName,
  int? size,
}) => StremioLinkChoice(
  installationId: 'addon',
  ref: _ref,
  label: name,
  stream: StremioStream(
    kind: StremioStreamKind.direct,
    url: 'https://cdn.example/$name',
    name: name,
    description: description,
    fileName: fileName,
    videoSize: size,
  ),
);

void main() {
  test('quality is read from name, description or file name', () {
    expect(stremioLinkQuality(_link('Torrentio 4k')), StremioLinkQuality.uhd);
    expect(
      stremioLinkQuality(_link('Addon', description: 'Movie.2160p.WEB')),
      StremioLinkQuality.uhd,
    );
    expect(
      stremioLinkQuality(_link('Addon', fileName: 'movie.1080p.mkv')),
      StremioLinkQuality.fullHd,
    );
    expect(stremioLinkQuality(_link('720p HDTV')), StremioLinkQuality.hd);
    expect(stremioLinkQuality(_link('Server 1')), StremioLinkQuality.other);
    // Digits inside other words never count ("x1080px" is not 1080p).
    expect(stremioLinkQuality(_link('h264 x1080px')), StremioLinkQuality.other);
    // The highest named resolution wins.
    expect(
      stremioLinkQuality(_link('4K', description: '1080p fallback')),
      StremioLinkQuality.uhd,
    );
  });

  test('search needs every word, case-insensitive, addon name included', () {
    final link = _link('Release', description: 'GROUP x265 HDR');
    expect(stremioLinkMatchesQuery(link, ''), isTrue);
    expect(stremioLinkMatchesQuery(link, 'group hdr'), isTrue);
    expect(stremioLinkMatchesQuery(link, 'group dv'), isFalse);
    expect(
      stremioLinkMatchesQuery(link, 'torrentio', addonName: 'Torrentio'),
      isTrue,
    );
  });

  test('filter combines quality and search', () {
    final links = [
      _link('4K', description: 'GROUP'),
      _link('1080p', description: 'GROUP'),
      _link('1080p', description: 'OTHER'),
    ];
    expect(
      filterStremioLinks(
        links,
        quality: StremioLinkQuality.fullHd,
        query: 'group',
      ).map((l) => l.stream.description),
      ['GROUP'],
    );
    expect(filterStremioLinks(links), hasLength(3));
    final counts = countStremioLinkQualities(links);
    expect(counts[StremioLinkQuality.uhd], 1);
    expect(counts[StremioLinkQuality.fullHd], 2);
    expect(counts[StremioLinkQuality.hd], 0);
  });

  test('size sort keeps unknown sizes last and ties in addon order', () {
    final links = [
      _link('a'),
      _link('b', size: 1),
      _link('c', size: 3),
      _link('d', size: 3),
      _link('e', size: 0),
    ];
    String names(List<StremioLinkChoice> l) => l.map((c) => c.label).join();
    expect(names(sortStremioLinks(links, StremioLinkSort.addonOrder)), 'abcde');
    expect(names(sortStremioLinks(links, StremioLinkSort.largestFirst)), 'cdbae');
    expect(
      names(sortStremioLinks(links, StremioLinkSort.smallestFirst)),
      'bcdae',
    );
  });

  test('copy title uses name and description, else the label', () {
    expect(stremioLinkTitle(_link('4K', description: 'WEB-DL')), '4K\nWEB-DL');
    expect(
      stremioLinkTitle(
        const StremioLinkChoice(
          installationId: 'addon',
          ref: _ref,
          label: 'Fallback',
          stream: StremioStream(kind: StremioStreamKind.direct),
        ),
      ),
      'Fallback',
    );
  });
}
