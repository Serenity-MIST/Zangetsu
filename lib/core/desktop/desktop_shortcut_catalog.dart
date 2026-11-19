import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'desktop_shortcuts.dart';

// Short builders so the table below reads like a key list.
SingleActivator _k(LogicalKeyboardKey key) => SingleActivator(key);
SingleActivator _ctrl(LogicalKeyboardKey key) =>
    SingleActivator(key, control: true);
SingleActivator _alt(LogicalKeyboardKey key) => SingleActivator(key, alt: true);
SingleActivator _shift(LogicalKeyboardKey key) =>
    SingleActivator(key, shift: true);

// '?' is stored as Shift+/; DesktopShortcuts matches it by character.
final SingleActivator _question = _shift(LogicalKeyboardKey.slash);

const _digits = [
  LogicalKeyboardKey.digit0,
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
];

/// Registers every Windows keyboard shortcut the app binds. Feature code
/// binds by these ids through [DesktopShortcuts], so ids must not change.
/// Safe to call more than once (registration is idempotent by id).
///
/// Labels here are the English source text; desktop_shortcut_labels.dart
/// translates them by id when they are shown.
void registerDefaultDesktopShortcuts() {
  const app = DesktopShortcutScope.app;
  const home = DesktopShortcutScope.home;
  const show = DesktopShortcutScope.showPage;
  const player = DesktopShortcutScope.player;
  const reader = DesktopShortcutScope.reader;
  const downloads = DesktopShortcutScope.downloads;
  const lists = DesktopShortcutScope.lists;
  const settings = DesktopShortcutScope.settings;

  // Player actions are remappable (player-5 B) except the percent jump and
  // Esc, which stay fixed so the user can always leave the player.
  DesktopShortcutSpec p(
    String id,
    String label,
    List<SingleActivator> keys, {
    bool remappable = true,
    String? description,
  }) => DesktopShortcutSpec(
    id: 'player.$id',
    scope: player,
    label: label,
    defaults: keys,
    remappable: remappable,
    description: description,
  );

  DesktopShortcutSpec s(
    String id,
    DesktopShortcutScope scope,
    String label,
    List<SingleActivator> keys, {
    String? description,
  }) => DesktopShortcutSpec(
    id: id,
    scope: scope,
    label: label,
    defaults: keys,
    description: description,
  );

  DesktopShortcuts.register([
    // ---- App-wide ----
    s('app.search', app, 'Search', [
      _ctrl(LogicalKeyboardKey.keyF),
      _k(LogicalKeyboardKey.slash),
    ]),
    for (var i = 1; i <= 9; i++)
      s('app.section$i', app, 'Go to sidebar item $i', [
        _ctrl(_digits[i]),
      ]),
    for (var i = 1; i <= 4; i++)
      s('app.mode$i', app, 'Switch to mode $i', [_alt(_digits[i])]),
    s('app.settings', app, 'Open Settings', [
      _ctrl(LogicalKeyboardKey.comma),
    ]),
    // History left the Windows sidebar; Ctrl+H opens it in the frame.
    // (Plain H stays the player's "Subtitles later".)
    s('app.history', app, 'Open History', [
      _ctrl(LogicalKeyboardKey.keyH),
    ]),
    s(
      'app.back',
      app,
      'Go back',
      [_alt(LogicalKeyboardKey.arrowLeft)],
      description: 'The mouse Back button also goes back',
    ),
    s('app.fullscreen', app, 'Toggle full screen', [
      _k(LogicalKeyboardKey.f11),
    ]),
    s('app.help', app, 'Show keyboard shortcuts', [
      _question,
      _ctrl(LogicalKeyboardKey.slash),
    ]),
    s('app.lockProfile', app, 'Lock profile now', [
      _ctrl(LogicalKeyboardKey.keyL),
    ]),
    s('app.refresh', app, 'Refresh', [
      _k(LogicalKeyboardKey.f5),
      _ctrl(LogicalKeyboardKey.keyR),
    ]),
    s('app.contextMenu', app, 'Open the menu for the focused item', [
      _k(LogicalKeyboardKey.contextMenu),
      _shift(LogicalKeyboardKey.f10),
    ]),
    // ---- Home ----
    s('home.first', home, 'First item in the row', [
      _k(LogicalKeyboardKey.home),
    ]),
    s('home.last', home, 'Last item in the row', [
      _k(LogicalKeyboardKey.end),
    ]),
    s('home.open', home, 'Open the focused title', [
      _k(LogicalKeyboardKey.enter),
    ]),
    // ---- Show page ----
    s('show.play', show, 'Play or continue', [
      _k(LogicalKeyboardKey.enter),
      _k(LogicalKeyboardKey.space),
    ]),
    s('show.download', show, 'Download the focused episode', [
      _k(LogicalKeyboardKey.keyD),
    ]),
    s('show.refreshEpisodes', show, 'Refresh episodes', [
      _k(LogicalKeyboardKey.f5),
    ]),
    // "Search", matching the box's placeholder ("filter" read oddly).
    s('show.filter', show, 'Search episodes', [
      _ctrl(LogicalKeyboardKey.keyF),
    ]),
    for (var i = 1; i <= 4; i++)
      s('show.tab$i', show, 'Go to tab $i', [_ctrl(_digits[i])]),
    s('show.selectAll', show, 'Select all episodes', [
      _ctrl(LogicalKeyboardKey.keyA),
    ]),
    s('show.clearSelection', show, 'Clear the selection', [
      _k(LogicalKeyboardKey.escape),
    ]),
    // ---- Player ----
    p('playPause', 'Play / pause', [
      _k(LogicalKeyboardKey.space),
      _k(LogicalKeyboardKey.keyK),
    ]),
    p('seekBack', 'Seek back', [
      _k(LogicalKeyboardKey.arrowLeft),
      _k(LogicalKeyboardKey.keyJ),
    ]),
    p('seekForward', 'Seek forward', [
      _k(LogicalKeyboardKey.arrowRight),
      _k(LogicalKeyboardKey.keyL),
    ]),
    p('seekBackLong', 'Seek back 1 minute', [
      _shift(LogicalKeyboardKey.arrowLeft),
    ]),
    p('seekForwardLong', 'Seek forward 1 minute', [
      _shift(LogicalKeyboardKey.arrowRight),
    ]),
    p('volumeUp', 'Volume up', [_k(LogicalKeyboardKey.arrowUp)]),
    p('volumeDown', 'Volume down', [_k(LogicalKeyboardKey.arrowDown)]),
    p('mute', 'Mute', [_k(LogicalKeyboardKey.keyM)]),
    p('fullscreen', 'Toggle full screen', [_k(LogicalKeyboardKey.keyF)]),
    p(
      'exit',
      'Leave full screen or the player',
      [_k(LogicalKeyboardKey.escape)],
      remappable: false,
    ),
    p('nextEpisode', 'Next episode', [_k(LogicalKeyboardKey.keyN)]),
    p('previousEpisode', 'Previous episode', [
      _k(LogicalKeyboardKey.keyP),
    ]),
    p('skip', 'Skip intro or ending', [_k(LogicalKeyboardKey.keyS)]),
    p('speedDown', 'Slower', [_k(LogicalKeyboardKey.bracketLeft)]),
    p('speedUp', 'Faster', [_k(LogicalKeyboardKey.bracketRight)]),
    p('subtitles', 'Subtitles on / off', [_k(LogicalKeyboardKey.keyC)]),
    p(
      'jumpPercent',
      'Jump to 0-90%',
      [for (final d in _digits) _k(d)],
      remappable: false,
    ),
    p(
      'frameBack',
      'Previous frame',
      [_k(LogicalKeyboardKey.comma)],
      description: 'While paused',
    ),
    p(
      'frameForward',
      'Next frame',
      [_k(LogicalKeyboardKey.period)],
      description: 'While paused',
    ),
    p('subDelayDown', 'Subtitles earlier', [
      _k(LogicalKeyboardKey.keyG),
    ]),
    p('subDelayUp', 'Subtitles later', [_k(LogicalKeyboardKey.keyH)]),
    p('miniPlayer', 'Mini player', [_ctrl(LogicalKeyboardKey.keyM)]),
    p('alwaysOnTop', 'Keep on top', [_ctrl(LogicalKeyboardKey.keyT)]),
    p('help', 'Show keyboard shortcuts', [_question]),
    // ---- Reader ----
    s('reader.nextPage', reader, 'Next page', [
      _k(LogicalKeyboardKey.arrowRight),
      _k(LogicalKeyboardKey.pageDown),
      _k(LogicalKeyboardKey.space),
    ]),
    s('reader.previousPage', reader, 'Previous page', [
      _k(LogicalKeyboardKey.arrowLeft),
      _k(LogicalKeyboardKey.pageUp),
      _shift(LogicalKeyboardKey.space),
    ]),
    s('reader.firstPage', reader, 'First page', [
      _k(LogicalKeyboardKey.home),
    ]),
    s('reader.lastPage', reader, 'Last page', [
      _k(LogicalKeyboardKey.end),
    ]),
    s('reader.nextChapter', reader, 'Next chapter', [
      _k(LogicalKeyboardKey.keyN),
      _k(LogicalKeyboardKey.bracketRight),
    ]),
    s('reader.previousChapter', reader, 'Previous chapter', [
      _k(LogicalKeyboardKey.keyP),
      _k(LogicalKeyboardKey.bracketLeft),
    ]),
    s('reader.chapterList', reader, 'Chapter list', [
      _k(LogicalKeyboardKey.keyC),
    ]),
    s('reader.settings', reader, 'Reader settings', [
      _k(LogicalKeyboardKey.keyS),
    ]),
    s('reader.autoScroll', reader, 'Auto-scroll', [
      _k(LogicalKeyboardKey.keyA),
    ]),
    s('reader.fullscreen', reader, 'Toggle full screen', [
      _k(LogicalKeyboardKey.keyF),
      _k(LogicalKeyboardKey.f11),
    ]),
    s('reader.toggleBars', reader, 'Show or hide the bars', [
      _k(LogicalKeyboardKey.keyM),
    ]),
    s('reader.back', reader, 'Leave the reader', [
      _k(LogicalKeyboardKey.backspace),
    ]),
    s('reader.zoomIn', reader, 'Zoom in', [
      _ctrl(LogicalKeyboardKey.equal),
    ]),
    s('reader.zoomOut', reader, 'Zoom out', [
      _ctrl(LogicalKeyboardKey.minus),
    ]),
    s('reader.zoomReset', reader, 'Reset zoom', [
      _ctrl(LogicalKeyboardKey.digit0),
    ]),
    s('reader.shiftSpread', reader, 'Shift two-page spread', [
      _k(LogicalKeyboardKey.keyO),
    ]),
    s('reader.help', reader, 'Show keyboard shortcuts', [_question]),
    // ---- Downloads ----
    s('downloads.selectAll', downloads, 'Select all', [
      _ctrl(LogicalKeyboardKey.keyA),
    ]),
    s('downloads.delete', downloads, 'Delete selected', [
      _k(LogicalKeyboardKey.delete),
    ]),
    s('downloads.clearSelection', downloads, 'Clear the selection', [
      _k(LogicalKeyboardKey.escape),
    ]),
    s('downloads.refresh', downloads, 'Refresh', [
      _k(LogicalKeyboardKey.f5),
    ]),
    s('downloads.open', downloads, 'Open the focused download', [
      _k(LogicalKeyboardKey.enter),
    ]),
    // ---- Lists (History, My List, Schedule) ----
    s(
      'lists.search',
      lists,
      'Search the list',
      [_ctrl(LogicalKeyboardKey.keyF)],
      description: 'History and My List',
    ),
    s('lists.refresh', lists, 'Refresh', [_k(LogicalKeyboardKey.f5)]),
    s(
      'lists.previousDay',
      lists,
      'Previous day',
      [_k(LogicalKeyboardKey.arrowLeft)],
      description: 'Schedule',
    ),
    s(
      'lists.nextDay',
      lists,
      'Next day',
      [_k(LogicalKeyboardKey.arrowRight)],
      description: 'Schedule',
    ),
    s(
      'lists.today',
      lists,
      'Today',
      [_k(LogicalKeyboardKey.home)],
      description: 'Schedule',
    ),
    // ---- Settings ----
    s('settings.search', settings, 'Search settings', [
      _ctrl(LogicalKeyboardKey.keyF),
      _ctrl(LogicalKeyboardKey.keyK),
    ]),
    s('settings.nextSection', settings, 'Next section', [
      _k(LogicalKeyboardKey.arrowDown),
    ]),
    s('settings.previousSection', settings, 'Previous section', [
      _k(LogicalKeyboardKey.arrowUp),
    ]),
  ]);
}
