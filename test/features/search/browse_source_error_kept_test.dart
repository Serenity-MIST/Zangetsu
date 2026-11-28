// src-11: BrowseSourceCubit keeps the caught error next to its failure flag,
// so the Windows screen can say "Source timed out" instead of a generic
// failure. Also covers dl-11's 'downloads' notification payload routing.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/source_timeout.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/notify/notification_router.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/features/search/cubit/browse_source_cubit.dart';

/// A source whose every call throws [error].
class _ThrowingRepo implements CatalogueRepository {
  _ThrowingRepo(this.error);
  final Object error;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  Future<List<HomeSection>> home({
    String category = 'sub',
    String? sourceId,
  }) async => throw error;

  @override
  Future<List<MediaItem>> search(
    String query, {
    String category = 'sub',
    String? sourceId,
  }) async => throw error;
}

void main() {
  test('search failure keeps a time-out error the screen can recognise',
      () async {
    final cubit = BrowseSourceCubit(
      repo: _ThrowingRepo(TimeoutException('slow')),
      sourceId: 'cs:Src',
    );
    await cubit.search('naruto');
    expect(cubit.state.searchFailed, isTrue);
    expect(isSourceTimeout(cubit.state.searchError), isTrue);
    expect(
      sourceFailureMessage(cubit.state.searchError, 'fallback'),
      startsWith('Source timed out'),
    );
    await cubit.close();
  });

  test('catalogue failure keeps its error; other errors stay generic',
      () async {
    final cubit = BrowseSourceCubit(
      repo: _ThrowingRepo(StateError('offline')),
      sourceId: 'cs:Src',
    );
    await cubit.load();
    expect(cubit.state.failed, isTrue);
    expect(cubit.state.loadError, isA<StateError>());
    expect(isSourceTimeout(cubit.state.loadError), isFalse);
    expect(sourceFailureMessage(cubit.state.loadError, 'fallback'), 'fallback');
    await cubit.close();
  });

  test("a 'downloads' notification click runs the shell's Downloads hook",
      () async {
    var opened = 0;
    openDownloadsFromNotification = () => opened++;
    addTearDown(() => openDownloadsFromNotification = null);
    await openShowFromNotification(downloadsNotificationPayload);
    expect(opened, 1);
  });
}
