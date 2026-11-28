import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/theme/app_colors.dart';
import 'package:watch_app/core/ui/desktop_docked_panel.dart';
import 'package:watch_app/core/ui/episode_player_sheet.dart';
import 'package:watch_app/features/downloads/episode_download_icon.dart';
import 'package:watch_app/features/player/player_screen.dart';
import 'package:watch_app/features/reader/desktop_page_scroller.dart';
import 'package:watch_app/features/watch_together/ui/room_panel.dart';
import 'package:watch_app/features/watch_together/watch_room_service.dart';
import 'package:watch_app/features/watch_together/watch_together_controller.dart';

/// Records pause/resume/cancel; nothing else is touched by the menu.
class _FakeDownloads implements DownloadManager {
  final calls = <String>[];

  @override
  Future<void> pause(DownloadRecord rec) async => calls.add('pause');

  @override
  Future<void> resume(DownloadRecord rec) async => calls.add('resume');

  @override
  Future<void> cancel(DownloadRecord rec) async => calls.add('cancel');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRoomService implements WatchRoomService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DownloadRecord _record(DownloadStatus status) => DownloadRecord(
  id: 'd1',
  sourceId: 'src',
  showId: 'show',
  showTitle: 'Frieren',
  showUrl: '/show/1',
  episodeId: 'ep1',
  episodeUrl: '/ep1',
  episodeNumber: 1,
  episodeTitle: 'Episode 1',
  category: 'sub',
  quality: '1080p',
  status: status,
  progress: .4,
  bytesTotal: 10,
  createdAt: 0,
);

/// The phone grabber: a 36x4 bar.
bool _isGrabber(Widget w) =>
    (w is SizedBox && w.width == 36 && w.height == 4) ||
    (w is Container &&
        w.constraints?.maxWidth == 36 &&
        w.constraints?.maxHeight == 4);

/// Pumps an "open" button under a stand-in for DesktopWindow's window-level
/// Esc binding (leave fullscreen), counting how often that binding fires.
Future<ValueNotifier<int>> _pumpOpener(
  WidgetTester tester,
  void Function(BuildContext) open,
) async {
  final windowEsc = ValueNotifier(0);
  await tester.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              windowEsc.value++,
        },
        child: Focus(autofocus: true, child: child!),
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => open(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return windowEsc;
}

Color _barrierColor(WidgetTester tester) =>
    tester.widgetList<ModalBarrier>(find.byType(ModalBarrier)).last.color!;

void main() {
  final windows = TargetPlatformVariant.only(TargetPlatform.windows);

  group('panel colours', () {
    tearDown(() => AppColors.bg = AppColors.defaultBg);

    test('stock background keeps the original greys exactly', () {
      AppColors.bg = AppColors.defaultBg;
      expect(DesktopPanelColors.surface, const Color(0xFF1A1B20));
      expect(DesktopPanelColors.edge, const Color(0xFF36373E));
    });

    test('Pure black and a custom background recolour the panels', () {
      AppColors.bg = const Color(0xFF000000);
      final black = DesktopPanelColors.surface;
      expect(black, isNot(const Color(0xFF1A1B20)));
      // Stays near-black: no grey slab on a Pure black theme.
      expect(black.computeLuminance(), lessThan(.01));
      expect(DesktopPanelColors.edge, isNot(const Color(0xFF36373E)));

      AppColors.bg = const Color(0xFF102040);
      final custom = DesktopPanelColors.surface;
      expect(custom, isNot(black));
      expect(custom.b, greaterThan(custom.r)); // follows the blue tint
    });

    testWidgets('the in-player docked panel uses the themed fill', (
      tester,
    ) async {
      AppColors.bg = const Color(0xFF000000);
      await _pumpOpener(
        tester,
        (context) => showDesktopPlayerPanel<void>(
          context,
          builder: (_) => const SizedBox(height: 100),
        ),
      );
      final dialog = tester.widget<Dialog>(
        find.byKey(const ValueKey('player-desktop-panel')),
      );
      expect(dialog.backgroundColor, DesktopPanelColors.surface);
      expect(dialog.backgroundColor, isNot(const Color(0xFF1A1B20)));
    }, variant: windows);
  });

  testWidgets('More panel: light scrim and Esc closes it, not fullscreen', (
    tester,
  ) async {
    final windowEsc = await _pumpOpener(tester, debugShowPlayerMorePanel);
    expect(find.text('Sleep timer'), findsOneWidget);
    expect(_barrierColor(tester), Colors.black26);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Sleep timer'), findsNothing);
    expect(windowEsc.value, 0);
  }, variant: windows);

  testWidgets('More panel keeps the darker phone scrim on Android', (
    tester,
  ) async {
    await _pumpOpener(tester, debugShowPlayerMorePanel);
    expect(find.text('Sleep timer'), findsOneWidget);
    expect(_barrierColor(tester), Colors.black54);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('reader panel: Esc closes it ahead of the window Esc', (
    tester,
  ) async {
    final windowEsc = await _pumpOpener(
      tester,
      (context) => showReaderPanel<void>(
        context: context,
        builder: (_) => const SizedBox(height: 200, child: Text('panel body')),
      ),
    );
    expect(find.text('panel body'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('panel body'), findsNothing);
    expect(windowEsc.value, 0);
  }, variant: windows);

  group('mirror picker', () {
    final sources = [
      VideoSource(url: 'https://a/1.m3u8', label: 'Server A'),
      VideoSource(url: 'https://a/2.m3u8', label: 'Server B'),
    ];

    testWidgets('docks right on Windows; click picks, Esc closes', (
      tester,
    ) async {
      VideoSource? picked;
      final windowEsc = await _pumpOpener(tester, (context) async {
        picked = await showMirrorSheet(
          context,
          episodeLabel: 'Episode 3',
          sources: sources,
        );
      });
      final panel = find.byKey(const ValueKey('mirror-desktop-panel'));
      expect(panel, findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byWidgetPredicate(_isGrabber), findsNothing);
      expect(tester.widget<Dialog>(panel).alignment, Alignment.centerRight);
      expect(_barrierColor(tester), Colors.black26);
      expect(find.text('Episode 3'), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-panel-close')), findsOneWidget);

      await tester.tap(find.text('Server B'));
      await tester.pumpAndSettle();
      expect(picked, same(sources[1]));
      expect(panel, findsNothing);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      expect(windowEsc.value, 0);
    }, variant: windows);

    testWidgets('right-click copies the mirror link on Windows', (
      tester,
    ) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _pumpOpener(
        tester,
        (context) => showMirrorSheet(
          context,
          episodeLabel: 'Episode 3',
          sources: sources,
        ),
      );
      await tester.tap(find.text('Server A'), buttons: kSecondaryButton);
      await tester.pump();
      expect(copied, 'https://a/1.m3u8');
      // Right-click copies only; the panel stays open.
      expect(
        find.byKey(const ValueKey('mirror-desktop-panel')),
        findsOneWidget,
      );
      await tester.pumpAndSettle(const Duration(seconds: 3));
    }, variant: windows);

    testWidgets('stays a bottom sheet on phones', (tester) async {
      await _pumpOpener(
        tester,
        (context) => showMirrorSheet(
          context,
          episodeLabel: 'Episode 3',
          sources: sources,
        ),
      );
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byKey(const ValueKey('mirror-desktop-panel')), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });

  group('episode actions menu', () {
    Future<EpisodeAction?> open(BuildContext context) => showEpisodeActionSheet(
      context,
      episodeLabel: 'Episode 7',
      currentPlayerLabel: 'Built-in',
      isWatched: false,
      tracksToServices: false,
    );

    // Windows: the episode menu is a compact right-click context menu
    // (show-5), not the old docked side panel.
    testWidgets('opens a context menu on Windows without the Android-only row', (
      tester,
    ) async {
      EpisodeAction? action;
      final windowEsc = await _pumpOpener(tester, (context) async {
        action = await open(context);
      });
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byWidgetPredicate(_isGrabber), findsNothing);
      expect(
        find.byKey(const ValueKey('episode-actions-desktop-panel')),
        findsNothing,
      );
      expect(find.text('Play mirror'), findsOneWidget);
      // External players are Android only.
      expect(find.text('Play with…'), findsNothing);

      await tester.tap(find.text('Play mirror'));
      await tester.pumpAndSettle();
      expect(action, EpisodeAction.playMirror);
      expect(find.text('Play mirror'), findsNothing);

      // Esc closes the menu without reaching the window Esc binding.
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Play mirror'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Play mirror'), findsNothing);
      expect(windowEsc.value, 0);
    }, variant: windows);

    testWidgets('stays the phone sheet with Play with… on phones', (
      tester,
    ) async {
      await _pumpOpener(tester, open);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byWidgetPredicate(_isGrabber), findsOneWidget);
      expect(find.text('Play with…'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('episode-actions-desktop-panel')),
        findsNothing,
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });

  group('download menu', () {
    testWidgets('centred dialog on Windows; click pauses, Esc closes', (
      tester,
    ) async {
      final manager = _FakeDownloads();
      final rec = _record(DownloadStatus.downloading);
      final windowEsc = await _pumpOpener(
        tester,
        (context) =>
            EpisodeDownloadIcon.showDownloadMenu(context, manager, rec),
      );
      final dialog = find.byKey(const ValueKey('download-menu-desktop-dialog'));
      expect(dialog, findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.widget<Dialog>(dialog).alignment, Alignment.center);
      expect(find.text('Episode 1'), findsOneWidget);
      expect(find.text('Frieren'), findsOneWidget);

      await tester.tap(find.text('Pause download'));
      await tester.pumpAndSettle();
      expect(manager.calls, ['pause']);
      expect(dialog, findsNothing);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(windowEsc.value, 0);
      expect(manager.calls, ['pause']);
    }, variant: windows);

    testWidgets('stays a bottom sheet on phones', (tester) async {
      await _pumpOpener(
        tester,
        (context) => EpisodeDownloadIcon.showDownloadMenu(
          context,
          _FakeDownloads(),
          _record(DownloadStatus.paused),
        ),
      );
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(
        find.byKey(const ValueKey('download-menu-desktop-dialog')),
        findsNothing,
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });

  group('Watch Together panels', () {
    late WatchTogetherController controller;
    setUp(() => controller = WatchTogetherController(_FakeRoomService()));

    for (final (name, key, open) in [
      (
        'participants',
        'room-participants-desktop-panel',
        showRoomParticipantsSheet,
      ),
      ('chat', 'room-chat-desktop-panel', showRoomChatSheet),
    ]) {
      testWidgets('$name docks right on Windows, no handle, Esc closes', (
        tester,
      ) async {
        final windowEsc = await _pumpOpener(
          tester,
          (context) => open(context, controller),
        );
        final panel = find.byKey(ValueKey(key));
        expect(panel, findsOneWidget);
        expect(find.byType(BottomSheet), findsNothing);
        expect(find.byWidgetPredicate(_isGrabber), findsNothing);
        expect(tester.widget<Dialog>(panel).alignment, Alignment.centerRight);
        expect(
          find.byKey(const ValueKey('desktop-panel-close')),
          findsOneWidget,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(panel, findsNothing);
        expect(windowEsc.value, 0);

        // The close button closes it too.
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('desktop-panel-close')));
        await tester.pumpAndSettle();
        expect(panel, findsNothing);
      }, variant: windows);

      if (name == 'chat') {
        testWidgets('chat: Esc while typing closes the panel', (tester) async {
          final windowEsc = await _pumpOpener(
            tester,
            (context) => open(context, controller),
          );
          await tester.tap(find.byType(TextField));
          await tester.enterText(find.byType(TextField), 'hi');
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.byKey(ValueKey(key)), findsNothing);
          expect(windowEsc.value, 0);
        }, variant: windows);
      }

      testWidgets('$name stays a bottom sheet on phones', (tester) async {
        await _pumpOpener(tester, (context) => open(context, controller));
        expect(find.byType(BottomSheet), findsOneWidget);
        expect(find.byKey(ValueKey(key)), findsNothing);
      }, variant: TargetPlatformVariant.only(TargetPlatform.android));
    }
  });
}
