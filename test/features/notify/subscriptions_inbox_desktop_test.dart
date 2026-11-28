// track-1: on Windows the Notifications page lists the in-app "New episodes"
// inbox with unread markers, mark-read and mark-all-read; phone keeps the old
// page without it.

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

NewEpisodeEntry _entry(String id, {bool read = false, int count = 2}) =>
    NewEpisodeEntry(
      id: id,
      showId: 'https://example.test/$id',
      sourceId: 'ani:1',
      title: 'Show $id',
      mode: 'anime',
      count: count,
      at: DateTime(2026, 1, 1),
      read: read,
    );

Widget _app() => const MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: SubscriptionsScreen(),
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

  testWidgets('Windows lists the inbox and marks entries read', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await NewEpisodeInbox.add(_entry('a'));
      await NewEpisodeInbox.add(_entry('b', read: true, count: 1));

      await tester.pumpWidget(_app());
      await tester.pump();

      expect(find.text('NEW EPISODES'), findsOneWidget);
      expect(find.text('Show a'), findsOneWidget);
      expect(find.textContaining('2 new episodes'), findsOneWidget);
      expect(find.textContaining('1 new episode'), findsOneWidget);
      expect(NewEpisodeInbox.unread.value, 1);

      // Only the unread row offers "Mark as read".
      expect(find.byIcon(Icons.mark_email_read_outlined), findsOneWidget);
      await tester.tap(find.byIcon(Icons.mark_email_read_outlined));
      await tester.pump();
      expect(NewEpisodeInbox.unread.value, 0);
      expect(find.byIcon(Icons.done_all_rounded), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Mark all read clears the badge count', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await NewEpisodeInbox.add(_entry('a'));
      await NewEpisodeInbox.add(
        NewEpisodeEntry(
          id: 'c',
          showId: 'https://example.test/c',
          sourceId: 'ani:2',
          title: 'Show c',
          mode: 'manga',
          count: 1,
          at: DateTime(2026, 1, 2),
        ),
      );
      await tester.pumpWidget(_app());
      await tester.pump();
      expect(find.textContaining('1 new chapter'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.done_all_rounded));
      await tester.pump();
      expect(NewEpisodeInbox.unread.value, 0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('phone does not show the inbox', (tester) async {
    await NewEpisodeInbox.add(_entry('a'));
    await tester.pumpWidget(_app());
    await tester.pump();
    expect(find.text('NEW EPISODES'), findsNothing);
    expect(find.text('Show a'), findsNothing);
  });
}
