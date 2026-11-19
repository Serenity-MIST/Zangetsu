import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:image/image.dart' as img;
import 'package:watch_app/core/desktop/desktop_clipboard_image.dart';
import 'package:watch_app/core/profiles/profile_avatar_uploader.dart';
import 'package:watch_app/core/profiles/profile_lock_store.dart';
import 'package:watch_app/core/profiles/viewer_profile.dart';
import 'package:watch_app/features/profiles/desktop_avatar_input.dart';
import 'package:watch_app/features/profiles/desktop_profile_relock.dart';
import 'package:watch_app/features/profiles/profile_launch_gate.dart';
import 'package:watch_app/features/profiles/viewer_profiles_screen.dart';

/// Windows profile work: "Who's watching" keys and menu (acct-7), relock
/// triggers (acct-11) and avatar drop / paste input (acct-6).
void main() {
  group('number keys', () {
    test('top row and numpad 1-9 map to positions', () {
      expect(desktopPickerDigitIndex(LogicalKeyboardKey.digit1), 0);
      expect(desktopPickerDigitIndex(LogicalKeyboardKey.digit5), 4);
      expect(desktopPickerDigitIndex(LogicalKeyboardKey.numpad3), 2);
      expect(desktopPickerDigitIndex(LogicalKeyboardKey.digit0), isNull);
      expect(desktopPickerDigitIndex(LogicalKeyboardKey.keyA), isNull);
    });
  });

  group('relock triggers', () {
    late DateTime now;
    late List<ProfileRelockReason> requests;
    late bool watching;
    late int idleMinutes;
    late bool lockWithWindows;

    DesktopProfileRelock make() => DesktopProfileRelock(
      onLockRequested: (reason) async => requests.add(reason),
      clock: () => now,
      isWatching: () async => watching,
      sessionLocked: const Stream.empty(),
      idleMinutes: () => idleMinutes,
      lockWhenWindowsLocks: () => lockWithWindows,
    );

    setUp(() {
      now = DateTime(2026, 1, 1, 12);
      requests = [];
      watching = false;
      idleMinutes = 5;
      lockWithWindows = false;
    });

    test('idle lock is off at 0 minutes', () async {
      idleMinutes = 0;
      final relock = make();
      now = now.add(const Duration(hours: 3));
      expect(relock.idleExpired(), isFalse);
      await relock.checkIdle();
      expect(requests, isEmpty);
    });

    test('locks after the idle time, input restarts the clock', () async {
      final relock = make();
      now = now.add(const Duration(minutes: 4));
      relock.recordInput();
      now = now.add(const Duration(minutes: 4));
      await relock.checkIdle();
      expect(requests, isEmpty);
      now = now.add(const Duration(minutes: 1));
      await relock.checkIdle();
      expect(requests, [ProfileRelockReason.idle]);
      // The clock restarted, so it does not ask again straight away.
      await relock.checkIdle();
      expect(requests, hasLength(1));
    });

    test('watching something counts as activity', () async {
      watching = true;
      final relock = make();
      now = now.add(const Duration(minutes: 30));
      await relock.checkIdle();
      expect(requests, isEmpty);
      expect(relock.idleExpired(), isFalse);
    });

    test('Windows locking only relocks when the setting is on', () {
      final relock = make();
      relock.onSessionLockChanged(true);
      expect(requests, isEmpty);
      lockWithWindows = true;
      relock.onSessionLockChanged(true);
      expect(requests, [ProfileRelockReason.windowsLocked]);
      relock.onSessionLockChanged(false);
      expect(requests, hasLength(1));
    });

    test('lockNow does nothing when no gate is running', () {
      expect(DesktopProfileRelock.lockNow(), isFalse);
    });
  });

  group('avatar input helpers', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('avatar_input');
    });

    tearDown(() async {
      debugAvatarDownloadOverride = null;
      debugClipboardImageOverride = null;
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('recognises image paths and GIF bytes', () {
      expect(desktopAvatarIsImagePath(r'C:\pics\me.PNG'), isTrue);
      expect(desktopAvatarIsImagePath('clip.webp'), isTrue);
      expect(desktopAvatarIsImagePath('notes.txt'), isFalse);
      expect(desktopAvatarIsImagePath('noext'), isFalse);
      expect(
        desktopAvatarLooksLikeGif(Uint8List.fromList('GIF89a..'.codeUnits)),
        isTrue,
      );
      expect(desktopAvatarLooksLikeGif(Uint8List.fromList([1, 2, 3])), isFalse);
    });

    test('reads a dropped file, refuses a non-image and a huge GIF', () async {
      final png = File('${dir.path}/a.png')..writeAsBytesSync([1, 2, 3]);
      final read = await readDesktopAvatarFile(png.path);
      expect(read?.bytes, [1, 2, 3]);

      final txt = File('${dir.path}/a.txt')..writeAsStringSync('x');
      expect(await readDesktopAvatarFile(txt.path), isNull);

      final gif = File('${dir.path}/big.gif');
      final raf = gif.openSync(mode: FileMode.write)
        ..setPositionSync(ProfileAvatarUploader.maxGifSourceBytes + 1)
        ..writeByteSync(0);
      raf.closeSync();
      final big = await readDesktopAvatarFile(gif.path);
      expect(big?.bytes, isNull);
      expect(big?.error, contains('too large'));
    });

    test('text drops: quoted paths, file URIs and image links', () async {
      final png = File('${dir.path}/b.png')..writeAsBytesSync([4, 5]);
      expect((await readDesktopAvatarText('"${png.path}"'))?.bytes, [4, 5]);
      expect(
        (await readDesktopAvatarText(Uri.file(png.path).toString()))?.bytes,
        [4, 5],
      );

      Uri? fetched;
      debugAvatarDownloadOverride = (url) async {
        fetched = url;
        return Uint8List.fromList([9]);
      };
      final link = await readDesktopAvatarText('https://x.test/cat.png\n');
      expect(fetched, Uri.parse('https://x.test/cat.png'));
      expect(link?.bytes, [9]);
      expect(await readDesktopAvatarText('   '), isNull);
    });

    test('paste prefers copied files, then a copied picture', () async {
      final png = File('${dir.path}/c.png')..writeAsBytesSync([7]);
      debugClipboardImageOverride = () async =>
          DesktopClipboardImage(paths: [png.path]);
      expect((await readDesktopAvatarClipboard())?.bytes, [7]);

      debugClipboardImageOverride = () async =>
          DesktopClipboardImage(imageBytes: Uint8List.fromList([8, 8]));
      expect((await readDesktopAvatarClipboard())?.bytes, [8, 8]);
    });

    test('clipboard bitmap becomes an opaque PNG', () {
      // A 2x1 32-bit DIB whose alpha bytes are all 0, as many apps copy.
      final dib = BytesBuilder();
      final header = ByteData(40)
        ..setUint32(0, 40, Endian.little)
        ..setInt32(4, 2, Endian.little)
        ..setInt32(8, 1, Endian.little)
        ..setUint16(12, 1, Endian.little)
        ..setUint16(14, 32, Endian.little)
        ..setUint32(16, 0, Endian.little);
      dib.add(header.buffer.asUint8List());
      dib.add([0, 0, 255, 0, 255, 0, 0, 0]); // red, blue (BGRA)
      final bmp = dibToBmp(dib.toBytes())!;
      expect(String.fromCharCodes(bmp.sublist(0, 2)), 'BM');
      expect(ByteData.sublistView(bmp).getUint32(10, Endian.little), 54);

      final png = normalizeClipboardBitmap(bmp)!;
      final decoded = img.decodePng(png)!;
      expect(decoded.width, 2);
      final first = decoded.getPixel(0, 0);
      expect(first.r, 255);
      expect(first.a, first.maxChannelValue);
    });
  });

  group('avatar drop zone', () {
    tearDown(() => debugClipboardImageOverride = null);

    // A visited tab stays alive behind the visible one (TickerMode off); its
    // avatar must not take a Ctrl+V meant for the page on screen.
    windowsTest('Ctrl+V only reaches the zone on the visible tab', (
      tester,
    ) async {
      debugClipboardImageOverride = () async =>
          DesktopClipboardImage(imageBytes: Uint8List.fromList([1, 2, 3]));
      final hidden = <Uint8List>[];
      final visible = <Uint8List>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              TickerMode(
                enabled: false,
                child: DesktopAvatarDropZone(
                  onImage: hidden.add,
                  onError: (_) {},
                  child: const SizedBox(width: 40, height: 40),
                ),
              ),
              DesktopAvatarDropZone(
                onImage: visible.add,
                onError: (_) {},
                child: const SizedBox(width: 40, height: 40),
              ),
            ],
          ),
        ),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(visible, hasLength(1));
      expect(visible.single, [1, 2, 3]);
      expect(hidden, isEmpty);
    });
  });
  group("Windows Who's watching", () {
    late Directory directory;
    late ViewerProfileStore profiles;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('desktop_picker');
      Hive.init(directory.path);
      await ViewerProfileStore.init();
      profiles = ViewerProfileStore();
      await profiles.loadForUser();
      await GetIt.instance.reset();
      GetIt.instance.registerSingleton<ViewerProfileStore>(profiles);
    });

    tearDown(() async {
      await GetIt.instance.reset();
      await Hive.deleteFromDisk();
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    Future<void> pumpPicker(
      WidgetTester tester, {
      VoidCallback? onSelected,
    }) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: ViewerProfilesScreen(
            selectionOnly: true,
            onSelected: onSelected,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Finder tile(String id) => find.byKey(ValueKey('desktop-picker-tile-$id'));

    bool tileFocused(WidgetTester tester, Finder finder) {
      final focus = tester.widget<Focus>(
        find.descendant(of: finder, matching: find.byType(Focus)).first,
      );
      return focus.focusNode?.hasFocus ?? false;
    }

    windowsTest('grid is centred and the last profile has focus', (
      tester,
    ) async {
      await pumpPicker(tester);

      final grid = tester.getRect(
        find.byKey(const ValueKey('profile-picker-grid')),
      );
      expect(grid.center.dy, inInclusiveRange(900 * 0.3, 900 * 0.7));
      expect(tileFocused(tester, tile(kDefaultProfileId)), isTrue);
    });

    windowsTest('arrows move focus, 1 picks the first profile', (tester) async {
      var selected = 0;
      await pumpPicker(tester, onSelected: () => selected++);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        tileFocused(
          tester,
          find.byKey(const ValueKey('desktop-picker-tile-action-Add')),
        ),
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(tileFocused(tester, tile(kDefaultProfileId)), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.pumpAndSettle();
      expect(selected, 1);
    });

    windowsTest('Enter opens the focused profile', (tester) async {
      var selected = 0;
      await pumpPicker(tester, onSelected: () => selected++);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(selected, 1);
    });

    windowsTest('right-click menu and tooltip', (tester) async {
      GetIt.instance.registerSingleton<ProfileLockStore>(_AlwaysLockedStore());
      await pumpPicker(tester);

      final tooltip = tester.widget<Tooltip>(
        find
            .descendant(
              of: tile(kDefaultProfileId),
              matching: find.byType(Tooltip),
            )
            .first,
      );
      expect(tooltip.message, contains('Press 1 to choose'));

      await tester.tap(tile(kDefaultProfileId), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Edit profile'), findsOneWidget);
      expect(find.text('Change PIN…'), findsOneWidget);
      // The main profile cannot be deleted.
      expect(find.text('Delete profile'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    });

    testWidgets('phone picker has no desktop tiles', (tester) async {
      await pumpPicker(tester);
      expect(tile(kDefaultProfileId), findsNothing);
    });

    windowsTest('Lock profile now stops at the picker again', (tester) async {
      await tester.runAsync(() => profiles.setAskOnLaunch(false));
      GetIt.instance.registerSingleton<ProfileLockStore>(_AlwaysLockedStore());
      await tester.pumpWidget(
        const MaterialApp(home: ProfileLaunchGate(child: Text('Main screen'))),
      );
      await tester.pumpAndSettle();
      expect(find.text('Main screen'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pumpAndSettle();
      // Plain L is not the shortcut.
      expect(find.text("Who's watching?"), findsNothing);

      expect(DesktopProfileRelock.lockNow(), isTrue);
      await tester.pumpAndSettle();
      expect(find.text("Who's watching?"), findsOneWidget);
    });

    windowsTest('a profile without a PIN says how to lock it', (tester) async {
      await tester.runAsync(() => profiles.setAskOnLaunch(false));
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ProfileLaunchGate(child: Text('Main screen'))),
        ),
      );
      await tester.pumpAndSettle();

      DesktopProfileRelock.lockNow();
      await tester.pumpAndSettle();
      expect(find.text("Who's watching?"), findsNothing);
      expect(
        find.text('Set a PIN for this profile to be able to lock it.'),
        findsOneWidget,
      );
    });
  });
}

/// A widget test run with Windows as the target platform (the variant
/// restores the platform afterwards, as flutter_test requires).
void windowsTest(String description, WidgetTesterCallback body) => testWidgets(
  description,
  body,
  variant: TargetPlatformVariant.only(TargetPlatform.windows),
);

class _AlwaysLockedStore extends ProfileLockStore {
  @override
  Future<bool> isLocked(String profileId) async => true;
}
