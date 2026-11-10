import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/metadata/tmdb.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/poster_card.dart';
import '../../core/ui/settings_widgets.dart';
import '../../core/ui/desktop_settings_surface.dart';

const _previewItem = MediaItem(
  id: 'tmdb:tv:76479',
  title: 'The Boys',
  englishTitle: 'The Boys',
  cover: '${Tmdb.img}/w500/in1R2dDc421JxsoRWaIIAqVI2KE.jpg',
  banner: '${Tmdb.img}/w780/bq28ajZaoMyzEIm6REelqyqtEDZ.jpg',
  url: 'preview:the-boys',
  type: ProviderType.movie,
  sourceId: 'poster-preview',
  genres: ['Action'],
  isAdult: true,
  tmdbId: 76479,
  tmdbIsTv: true,
);

const _previewItems = [
  _previewItem,
  MediaItem(
    id: 'tmdb:tv:1396',
    title: 'Breaking Bad',
    englishTitle: 'Breaking Bad',
    cover: '${Tmdb.img}/w500/ggFHVNu6YYI5L9pCfOacjizRGt.jpg',
    banner: '${Tmdb.img}/w780/bsNm9z2TJfe0WO3RedPGWQ8mG1X.jpg',
    url: 'preview:breaking-bad',
    type: ProviderType.movie,
    sourceId: 'poster-preview',
    genres: ['Crime'],
  ),
  MediaItem(
    id: 'tmdb:tv:94605',
    title: 'Arcane',
    englishTitle: 'Arcane',
    cover: '${Tmdb.img}/w500/fqldf2t8ztc9aiwn3k6mlX3tvRT.jpg',
    url: 'preview:arcane',
    type: ProviderType.movie,
    sourceId: 'poster-preview',
    genres: ['Animation'],
  ),
];

/// Poster appearance controls; desktop uses a bounded renderer preview and
/// separate inspector, while mobile keeps its established presentation.
class PosterCardSettingsScreen extends StatefulWidget {
  const PosterCardSettingsScreen({super.key});

  @override
  State<PosterCardSettingsScreen> createState() =>
      _PosterCardSettingsScreenState();
}

class _PosterCardSettingsScreenState extends State<PosterCardSettingsScreen> {
  PlaybackPrefs get prefs => sl<PlaybackPrefs>();
  bool _cataloguePreview = false;

  Future<void> _change(Future<void> change) async {
    await change;
    if (mounted) setState(() {});
  }

  Widget _switch(
    IconData icon,
    String title,
    String subtitle,
    bool value,
    Future<void> Function(bool) save, {
    bool enabled = true,
  }) {
    void flip(bool selected) => _change(save(selected));
    return SettingsTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      subtitleMaxLines: 2,
      onTap: enabled ? () => flip(!value) : null,
      trailing: Switch.adaptive(
        value: value,
        activeThumbColor: AppColors.accent,
        onChanged: enabled ? flip : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = prefs.posterCardLayout == PosterCardLayout.wide;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar('Poster cards'),
      body: DesktopSettingsScope.contains(context)
          ? _desktopBody(wide)
          : ListView(
              padding: const EdgeInsets.only(top: 4, bottom: 32),
              children: [
                const SettingsSectionLabel('Preview', first: true),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final gridColumns = posterGridColumns(context);
                    final sampleCount = gridColumns
                        .clamp(1, _previewItems.length)
                        .toInt();
                    final rowWidth = constraints.maxWidth.clamp(0.0, 440.0);
                    final width =
                        (rowWidth - 32 - 12 * (gridColumns - 1)) / gridColumns;
                    final previewWidth =
                        (width * sampleCount + 12 * (sampleCount - 1) + 32)
                            .clamp(0.0, rowWidth)
                            .toDouble();
                    final height = posterCellHeight(
                      width,
                      wide: wide,
                      titleInside: posterTitleInside(context, wide: wide),
                    );
                    return SizedBox(
                      height: height + 12,
                      child: Center(
                        child: SizedBox(
                          width: previewWidth,
                          height: height,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              children: [
                                for (
                                  var index = 0;
                                  index < sampleCount;
                                  index++
                                ) ...[
                                  if (index == 1)
                                    const VerticalDivider(
                                      width: 12,
                                      thickness: 1,
                                      color: AppColors.textTertiary,
                                    )
                                  else if (index > 1)
                                    const SizedBox(width: 12),
                                  SizedBox(
                                    width: width,
                                    height: height,
                                    child: PosterCard(
                                      title: _previewItems[index].title,
                                      imageUrl: _previewItems[index].cover,
                                      wideImageUrl: _previewItems[index].banner,
                                      logoItem: index == 0
                                          ? _previewItem
                                          : null,
                                      cellWidth: width,
                                      qualityBadge: index == 0 ? 'HD' : null,
                                      genres: _previewItems[index].genres,
                                      isAdult: _previewItems[index].isAdult,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SettingsSectionLabel('Shape'),
                SettingsCard(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<PosterCardLayout>(
                          segments: const [
                            ButtonSegment(
                              value: PosterCardLayout.portrait,
                              label: Text('Portrait'),
                              icon: Icon(Icons.crop_portrait_rounded),
                            ),
                            ButtonSegment(
                              value: PosterCardLayout.wide,
                              label: Text('Landscape'),
                              icon: Icon(Icons.crop_landscape_rounded),
                            ),
                          ],
                          selected: {prefs.posterCardLayout},
                          onSelectionChanged: (value) =>
                              _change(prefs.setPosterCardLayout(value.first)),
                        ),
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: Text(
                    'Landscape uses a backdrop when available. Otherwise the full poster fits without cropping.',
                    style: AppText.caption,
                  ),
                ),
                const SettingsSectionLabel('Size'),
                SettingsCard(
                  children: [
                    _sizeControl(
                      'Portrait card size',
                      prefs.posterPortraitSize,
                      prefs.setPosterPortraitSize,
                    ),
                    _sizeControl(
                      'Landscape card size',
                      prefs.posterLandscapeSize,
                      prefs.setPosterLandscapeSize,
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: Text(
                    'Card size applies to poster rows and grids throughout the app.',
                    style: AppText.caption,
                  ),
                ),
                const SettingsSectionLabel('Title'),
                SettingsCard(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(bottom: 10),
                            child: Text('Title placement'),
                          ),
                          SizedBox(
                            width: double.infinity,
                            child: SegmentedButton<PosterTitlePlacement>(
                              segments: const [
                                ButtonSegment(
                                  value: PosterTitlePlacement.adaptive,
                                  label: Text('Automatic'),
                                ),
                                ButtonSegment(
                                  value: PosterTitlePlacement.inside,
                                  label: Text('Inside image'),
                                ),
                                ButtonSegment(
                                  value: PosterTitlePlacement.below,
                                  label: Text('Below image'),
                                ),
                              ],
                              selected: {prefs.posterTitlePlacement},
                              onSelectionChanged: (value) => _change(
                                prefs.setPosterTitlePlacement(value.first),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    _switch(
                      Icons.title_rounded,
                      'Title artwork',
                      'Use the real logo when available; otherwise show text',
                      prefs.posterTitleStyle == PosterTitleStyle.artwork,
                      (enabled) => prefs.setPosterTitleStyle(
                        enabled
                            ? PosterTitleStyle.artwork
                            : PosterTitleStyle.text,
                      ),
                    ),
                  ],
                ),
                const SettingsSectionLabel('Labels'),
                SettingsCard(
                  children: [
                    _switch(
                      Icons.hd_outlined,
                      'Quality',
                      'Shown when the source reports it',
                      prefs.posterQualityBadge,
                      prefs.setPosterQualityBadge,
                    ),
                    _switch(
                      Icons.subtitles_outlined,
                      'Sub / dub',
                      'Shown when the source reports it',
                      prefs.posterAudioBadge,
                      prefs.setPosterAudioBadge,
                    ),
                    _switch(
                      Icons.star_outline_rounded,
                      'Score',
                      'Catalogue rating when available',
                      prefs.posterScoreBadge,
                      prefs.setPosterScoreBadge,
                    ),
                    _switch(
                      Icons.category_outlined,
                      'Genre',
                      wide
                          ? 'First available genre'
                          : 'Only available on landscape cards',
                      prefs.posterGenreBadge,
                      prefs.setPosterGenreBadge,
                      enabled: wide,
                    ),
                    _switch(
                      Icons.eighteen_up_rating_outlined,
                      '18+ rating',
                      'Only for titles explicitly marked adult',
                      prefs.posterAdultBadge,
                      prefs.setPosterAdultBadge,
                    ),
                    _switch(
                      Icons.timelapse_rounded,
                      'Watch progress',
                      'Only where your tracker supplies a watched count',
                      prefs.posterProgressBadge,
                      prefs.setPosterProgressBadge,
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  /// Responsive desktop inspector keeps actual card scale separate from the
  /// number of grid columns in the full application window.
  Widget _desktopBody(bool wide) {
    final inspector = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GraphiteSettingsPanel(
          margin: EdgeInsets.zero,
          children: [
            _desktopChoices<PosterCardLayout>(
              'Shape',
              prefs.posterCardLayout,
              const [
                (PosterCardLayout.portrait, 'Portrait'),
                (PosterCardLayout.wide, 'Landscape'),
              ],
              prefs.setPosterCardLayout,
            ),
            _desktopChoices<PosterTitlePlacement>(
              'Title placement',
              prefs.posterTitlePlacement,
              const [
                (PosterTitlePlacement.adaptive, 'Automatic'),
                (PosterTitlePlacement.inside, 'Inside image'),
                (PosterTitlePlacement.below, 'Below image'),
              ],
              prefs.setPosterTitlePlacement,
            ),
            _switch(
              Icons.title_rounded,
              'Title artwork',
              'Use the real logo when available; otherwise show text',
              prefs.posterTitleStyle == PosterTitleStyle.artwork,
              (value) => prefs.setPosterTitleStyle(
                value ? PosterTitleStyle.artwork : PosterTitleStyle.text,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        GraphiteSettingsPanel(
          margin: EdgeInsets.zero,
          children: [
            _desktopChoices<PosterCardSize>(
              'Portrait card size',
              prefs.posterPortraitSize,
              const [
                (PosterCardSize.small, 'Small'),
                (PosterCardSize.standard, 'Default'),
                (PosterCardSize.large, 'Large'),
              ],
              prefs.setPosterPortraitSize,
            ),
            _desktopChoices<PosterCardSize>(
              'Landscape card size',
              prefs.posterLandscapeSize,
              const [
                (PosterCardSize.small, 'Small'),
                (PosterCardSize.standard, 'Default'),
                (PosterCardSize.large, 'Large'),
              ],
              prefs.setPosterLandscapeSize,
            ),
          ],
        ),
        const SizedBox(height: 16),
        GraphiteSettingsPanel(
          margin: EdgeInsets.zero,
          children: [
            _switch(
              Icons.hd_outlined,
              'Quality',
              'Shown when the source reports it',
              prefs.posterQualityBadge,
              prefs.setPosterQualityBadge,
            ),
            _switch(
              Icons.subtitles_outlined,
              'Sub / dub',
              'Shown when the source reports it',
              prefs.posterAudioBadge,
              prefs.setPosterAudioBadge,
            ),
            _switch(
              Icons.star_outline_rounded,
              'Score',
              'Catalogue rating when available',
              prefs.posterScoreBadge,
              prefs.setPosterScoreBadge,
            ),
            _switch(
              Icons.category_outlined,
              'Genre',
              wide
                  ? 'First available genre'
                  : 'Only available on landscape cards',
              prefs.posterGenreBadge,
              prefs.setPosterGenreBadge,
              enabled: wide,
            ),
            _switch(
              Icons.eighteen_up_rating_outlined,
              '18+ rating',
              'Only for titles explicitly marked adult',
              prefs.posterAdultBadge,
              prefs.setPosterAdultBadge,
            ),
            _switch(
              Icons.timelapse_rounded,
              'Watch progress',
              'Only where your tracker supplies a watched count',
              prefs.posterProgressBadge,
              prefs.setPosterProgressBadge,
            ),
          ],
        ),
      ],
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.all(22),
      child: LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth >= 1000
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 340, child: _desktopPreview(wide)),
                  const SizedBox(width: 20),
                  Expanded(child: inspector),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _desktopPreview(wide),
                  const SizedBox(height: 20),
                  inspector,
                ],
              ),
      ),
    );
  }

  /// Wrapping desktop choices retain full translated labels at larger text.
  Widget _desktopChoices<T>(
    String title,
    T current,
    List<(T, String)> options,
    Future<void> Function(T) save,
  ) => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AppText.body),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (value, label) in options)
              ChoiceChip(
                key: ValueKey('$title-$label'),
                label: Text(label),
                selected: current == value,
                onSelected: (selected) {
                  if (selected) _change(save(value));
                },
              ),
          ],
        ),
      ],
    ),
  );

  /// Use the real PosterCard renderer at Home's row width. Source and catalogue
  /// samples are separate because quality and score occupy the same badge slot.
  Widget _desktopPreview(bool wide) => GraphiteSettingsPanel(
    margin: EdgeInsets.zero,
    children: [
      Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Preview', style: AppText.headline),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  key: const ValueKey('poster-preview-source'),
                  label: const Text('Source'),
                  selected: !_cataloguePreview,
                  onSelected: (_) => setState(() => _cataloguePreview = false),
                ),
                ChoiceChip(
                  key: const ValueKey('poster-preview-catalogue'),
                  label: const Text('Catalogue'),
                  selected: _cataloguePreview,
                  onSelected: (_) => setState(() => _cataloguePreview = true),
                ),
              ],
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final width = posterRowWidth(
                  context,
                ).clamp(1.0, constraints.maxWidth);
                final item = _cataloguePreview
                    ? _previewItems[1]
                    : _previewItem;
                final height = posterCellHeight(
                  width,
                  wide: wide,
                  titleInside: posterTitleInside(context, wide: wide),
                );
                return Center(
                  child: SizedBox(
                    key: const ValueKey('desktop-poster-preview'),
                    width: width,
                    height: height,
                    child: PosterCard(
                      title: item.title,
                      imageUrl: item.cover,
                      wideImageUrl: item.banner,
                      logoItem: _cataloguePreview ? null : item,
                      cellWidth: width,
                      qualityBadge: _cataloguePreview ? null : 'HD',
                      dubBadge: _cataloguePreview ? null : 'SUB DUB',
                      scoreBadge: _cataloguePreview ? 87 : null,
                      progressBadge: _cataloguePreview ? null : '3 / 8',
                      genres: item.genres,
                      isAdult: item.isAdult,
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            Text(
              _cataloguePreview
                  ? 'Catalogue ratings appear when supplied by the catalogue.'
                  : 'Source labels and progress appear only when that information is available.',
              style: AppText.caption,
            ),
          ],
        ),
      ),
    ],
  );

  Widget _sizeControl(
    String title,
    PosterCardSize size,
    Future<void> Function(PosterCardSize) save,
  ) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(title)),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<PosterCardSize>(
            segments: const [
              ButtonSegment(value: PosterCardSize.small, label: Text('Small')),
              ButtonSegment(
                value: PosterCardSize.standard,
                label: Text('Default'),
              ),
              ButtonSegment(value: PosterCardSize.large, label: Text('Large')),
            ],
            selected: {size},
            onSelectionChanged: (selected) => _change(save(selected.first)),
          ),
        ),
      ],
    ),
  );
}
