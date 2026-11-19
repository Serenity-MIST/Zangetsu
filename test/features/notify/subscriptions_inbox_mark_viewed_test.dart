// shell-9: on Windows the new-episode inbox entries count as read once the
// user leaves the Notifications page (hidden by the shell or popped), so the
// bell badge clears. Phone keeps its unread entries.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:watch_app/core/announce/announcement.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/notify/new_episode_inbox.dart';
import 'package:watch_app/core/notify/subscription_store.dart';
import 'package:watch_app/features/notify/subscriptions_screen.dart';
import 'package:watch_app/l10n/app_localizations.dart';

/// No subscriptions; the page only needs [all].
class _Subs extends SubscriptionStore {
  @override
  List<Subscription> all() => const [];
}

/// No announcements, nothing to mark seen.
class _Announcements implements AnnouncementStore {
  @override
  List<Announcement> all() => const [];

  @override
  Future<void> markAllSeen() async {}

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

NewEpisodeEntry _entry(String id) => NewEpisodeEntry(
  id: id,
  showId: 'https://example.test/$id',
  sourceId: 'ani:1',
  title: 'Show $id',
  mode: 'anime',
  count: 2,
  at: DateTime(2026, 1, 1),
);

/// The page under a TickerMode the test flips, like the shell's
/// IndexedStack does when another in-frame page is selected.
Widget _app(ValueNotifier<bool> visible) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: ValueListenableBuilder<bool>(
    valueListenable: visible,
    builder: (context, on, _) =>
        TickerMode(enabled: on, child: const SubscriptionsScreen()),
  ),
);

void main() {
  setUp(() {
    NewEpisodeInbox.debugReset();
    GetIt.instance
      ..registerSingleton<SubscriptionStore>(_Subs())
      ..registerSingleton<AnnouncementStore>(_Announcements())
      ..registerSingleton<AppMode>(const AppMode(isTv: false));
  });

  tearDown(() async {
    NewEpisodeInbox.debugReset();
    await GetIt.instance.reset();
  });

  testWidgets('Windows marks the inbox read when the page is left', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final visible = ValueNotifier(true);
    try {
      await NewEpisodeInbox.add(_entry('a'));
      await NewEpisodeInbox.add(_entry('b'));
      await tester.pumpWidget(_app(visible));
      await tester.pump();
      // Still unread while the list is on screen (dots stay visible).
      expect(NewEpisodeInbox.unread.value, 2);

      // The shell hides the page: the viewed entries become read.
      visible.value = false;
      await tester.pump();
      await tester.pump();
      expect(NewEpisodeInbox.unread.value, 0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      visible.dispose();
    }
  });

  testWidgets('Windows marks the inbox read when the page is closed', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final visible = ValueNotifier(true);
    try {
      await NewEpisodeInbox.add(_entry('a'));
      await tester.pumpWidget(_app(visible));
      await tester.pump();
      expect(NewEpisodeInbox.unread.value, 1);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(NewEpisodeInbox.unread.value, 0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      visible.dispose();
    }
  });

  testWidgets('Windows keeps entries unread under a pushed route', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final visible = ValueNotifier(true);
    try {
      await NewEpisodeInbox.add(_entry('a'));
      await tester.pumpWidget(_app(visible));
      await tester.pump();
      // Something opened on top (like a show from the inbox) is not leaving
      // Notifications, even though it hides the page and its tickers.
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        nav.push(MaterialPageRoute<void>(builder: (_) => const Text('Detail'))),
      );
      await tester.pumpAndSettle();
      expect(NewEpisodeInbox.unread.value, 1);

      // Back on the page, then the shell hides it: now it counts as read.
      nav.pop();
      await tester.pumpAndSettle();
      expect(NewEpisodeInbox.unread.value, 1);
      visible.value = false;
      await tester.pump();
      await tester.pump();
      expect(NewEpisodeInbox.unread.value, 0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      visible.dispose();
    }
  });

  testWidgets('phone leaves inbox entries unread', (tester) async {
    final visible = ValueNotifier(true);
    try {
      await NewEpisodeInbox.add(_entry('a'));
      await tester.pumpWidget(_app(visible));
      await tester.pump();
      visible.value = false;
      await tester.pump();
      expect(NewEpisodeInbox.unread.value, 1);
    } finally {
      visible.dispose();
    }
  });
}
