// track-6: the checker only records a new episode count once the user was
// actually told (alert or inbox entry), so a check where alerts don't exist
// no longer uses the new episode up silently. track-1: the Windows inbox
// entry adds up unread counts for the same show.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/notify/new_episode_inbox.dart';
import 'package:watch_app/core/notify/notification_router.dart';
import 'package:watch_app/core/notify/subscription_checker.dart';
import 'package:watch_app/core/notify/subscription_store.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';

/// Answers every show with a fixed episode count.
class _Repo implements CatalogueRepository {
  _Repo(this.count);
  final int count;

  @override
  Future<List<Episode>> episodes(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) async => [
    for (var i = 0; i < count; i++)
      Episode(id: '$i', number: i + 1, title: 'Ep $i', url: '$url/$i'),
  ];

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Subscription _sub({int lastCount = 2, ContentMode mode = ContentMode.anime}) =>
    Subscription(
      sourceId: 'ani:1',
      url: 'https://example.test/show/1',
      title: 'A Show',
      lastCount: lastCount,
      mode: mode,
    );

void main() {
  late Directory dir;
  late SubscriptionStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('subdeliver');
    Hive.init(dir.path);
    await SubscriptionStore.init();
    store = SubscriptionStore();
    NewEpisodeInbox.debugReset();
  });

  tearDown(() async {
    NewEpisodeInbox.debugReset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('a new episode nobody was told about is not recorded', () async {
    await store.add(_sub());
    final found = await SubscriptionChecker(
      _Repo(5),
      store,
      deliver: (_, _) async => false,
    ).checkAll();

    expect(found, 0);
    expect(store.all().single.lastCount, 2, reason: 'kept for the next try');
  });

  test('a delivered new episode is recorded and counted', () async {
    await store.add(_sub());
    final told = <int>[];
    final found = await SubscriptionChecker(
      _Repo(5),
      store,
      deliver: (_, count) async {
        told.add(count);
        return true;
      },
    ).checkAll();

    expect(found, 1);
    expect(told, [5]);
    expect(store.all().single.lastCount, 5);
  });

  test('the first sweep after subscribing only records the baseline', () async {
    await store.add(_sub(lastCount: 0));
    var asked = false;
    await SubscriptionChecker(
      _Repo(7),
      store,
      deliver: (_, _) async => asked = true,
    ).checkAll();

    expect(asked, isFalse, reason: 'no alert for the existing episodes');
    expect(store.all().single.lastCount, 7);
  });

  test('inbox entries for the same show add up while unread', () async {
    await addToNewEpisodeInbox(_sub(lastCount: 2), 4); // +2
    await addToNewEpisodeInbox(_sub(lastCount: 4), 5); // +1
    final entries = NewEpisodeInbox.entries;
    expect(entries, hasLength(1), reason: 'one entry per show');
    expect(entries.single.count, 3);
    expect(entries.single.mode, 'anime');
    expect(NewEpisodeInbox.unread.value, 1);

    // Once read, the next arrival starts a fresh count.
    await NewEpisodeInbox.markRead(entries.single.id);
    await addToNewEpisodeInbox(_sub(lastCount: 5), 6);
    expect(NewEpisodeInbox.entries.single.count, 1);
  });

  test('marking a show read clears its inbox entries', () async {
    await addToNewEpisodeInbox(_sub(), 3);
    await markInboxShowRead('ani:1', 'https://example.test/show/1');
    expect(NewEpisodeInbox.unread.value, 0);
  });

  test('subscriptions open with their real type', () {
    expect(providerTypeForMode(ContentMode.manga), ProviderType.manga);
    expect(providerTypeForMode(ContentMode.novel), ProviderType.novel);
    expect(providerTypeForMode(null), ProviderType.anime);
    expect(
      subscriptionMediaItem(_sub(mode: ContentMode.manga)).type,
      ProviderType.manga,
    );
    expect(contentModeNamed('novel'), ContentMode.novel);
    expect(contentModeNamed('bogus'), isNull);
  });

  // Check now during the timer's sweep must get that sweep's answer, not a
  // "nothing new" 0 from being turned away.
  test('an overlapping call shares the running sweep', () async {
    await store.add(_sub());
    var deliveries = 0;
    final checker = SubscriptionChecker(
      _Repo(5),
      store,
      deliver: (_, _) async {
        deliveries++;
        return true;
      },
    );
    final results = await Future.wait([checker.checkAll(), checker.checkAll()]);
    expect(results, [1, 1]);
    expect(deliveries, 1, reason: 'one sweep, not two');
    // Once finished, a later call runs a fresh sweep (nothing new now).
    expect(await checker.checkAll(), 0);
  });
}
