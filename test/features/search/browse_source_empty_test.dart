// A source that answers with nothing used to be a dead end: the screen said
// "no titles" and stopped there, while the two things that actually fix it — a
// retry, or solving the Cloudflare challenge that suppressed the request —
// were buried in an overflow menu with no reason to open it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/provider/base_provider.dart';
import 'package:watch_app/core/provider/cf_solve_needed.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/features/search/browse_source_screen.dart';

class _EmptyRepo implements SourceRepository {
  int homeCalls = 0;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  // Added with the on-demand resolver: SourceMatcher now asks whether a JS
  // provider is loaded before searching it. These fakes are already "loaded".
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  Future<List<HomeSection>> home({
    String category = 'sub',
    String? sourceId,
  }) async {
    homeCalls++;
    return const [];
  }

  @override
  String baseUrlFor(String sourceId) => 'https://dead.example';

  @override
  Future<String?> cfSolveTargetFor(String sourceId) async =>
      'https://dead.example';

  @override
  String displayName(String sourceId) => sourceId;

  @override
  String? languageFor(String sourceId) => null;
}

class _FakeCloudStreamManager extends ChangeNotifier
    implements CloudStreamManager {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  BaseProvider? get(String sourceId) => null;
  @override
  String? repoNameForSourceId(String sourceId) => null;
}

void main() {
  late _EmptyRepo repo;

  Widget harness(Widget child) => MaterialApp(home: child);

  setUp(() {
    // This widget contract does not start the desktop plugin engine.
    cloudStreamHostOverride = (method, args) async => false;
    repo = _EmptyRepo();
    sl.registerSingleton<ActiveSourceCubit>(
      ActiveSourceCubit(fallback: 'cs:1'),
    );
    sl.registerSingleton<CloudStreamManager>(_FakeCloudStreamManager());
    sl.registerSingleton<SourceRepository>(repo);
  });

  tearDown(() async {
    cloudStreamHostOverride = null;
    CfSolveNeeded.clear('dead.example');
    await sl<ActiveSourceCubit>().close();
    await sl.reset();
  });

  testWidgets('an empty source offers a retry, and it reloads', (t) async {
    await t.pumpWidget(
      harness(const BrowseSourceScreen(sourceId: 'cs:Dead', title: 'Dead')),
    );
    await t.pumpAndSettle();

    expect(find.text('Retry'), findsOneWidget);
    final before = repo.homeCalls;

    await t.tap(find.text('Retry'));
    await t.pumpAndSettle();

    expect(repo.homeCalls, greaterThan(before));
  });

  testWidgets('a Cloudflare-blocked source offers the solve instead', (
    t,
  ) async {
    // Retrying a suppressed request just fails again; the challenge is the
    // thing standing in the way, so that is the action to offer.
    CfSolveNeeded.needsSolve(
      'dead.example',
      'https://dead.example',
      sourceId: 'cs:Dead',
    );

    await t.pumpWidget(
      harness(const BrowseSourceScreen(sourceId: 'cs:Dead', title: 'Dead')),
    );
    await t.pumpAndSettle();

    expect(find.text('Solve Cloudflare'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('completed native verification retries browsing immediately', (
    t,
  ) async {
    const channel = MethodChannel('zangetsu/mihon');
    var solves = 0;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'solveCloudflare') {
        solves++;
        return null;
      }
      return false;
    });
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    CfSolveNeeded.needsSolve(
      'dead.example',
      'https://dead.example',
      sourceId: 'mihon:1',
    );
    await t.pumpWidget(
      harness(const BrowseSourceScreen(sourceId: 'mihon:1', title: 'Native')),
    );
    await t.pumpAndSettle();
    final before = repo.homeCalls;
    await t.tap(find.text('Solve Cloudflare'));
    await t.pumpAndSettle();
    expect(solves, 1);
    expect(repo.homeCalls, before + 1);
  });
}
