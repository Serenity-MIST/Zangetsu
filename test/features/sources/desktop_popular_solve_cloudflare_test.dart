// Windows Sources page: the "Popular on <source>" row offers Solve Cloudflare
// next to Retry when a source is blocked by a Cloudflare check, and reloads
// the row by itself once the verification passed.
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/error/exceptions.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/provider/cf_solve_needed.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/features/search/cubit/browse_source_cubit.dart';
import 'package:watch_app/features/sources/desktop_source_popular_row.dart';

/// Catalogue whose home answers from a queue: each [home] call takes the next
/// entry (an exception is thrown, a list is returned). Everything else is
/// unused by the row.
class _QueuedRepo implements CatalogueRepository {
  _QueuedRepo(this.answers);

  final List<Object> answers;
  int homeCalls = 0;

  @override
  Future<List<HomeSection>> home({
    String category = 'sub',
    String? sourceId,
  }) async {
    final answer = answers[homeCalls.clamp(0, answers.length - 1)];
    homeCalls++;
    if (answer is List<HomeSection>) return answer;
    throw answer;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _sourceId = 'mihon:123';
const _challengeUrl = 'https://www.natomanga.com/manga-list/hot-manga?page=1';

void main() {
  tearDown(() => CfSolveNeeded.clear('www.natomanga.com'));

  /// Pumps the row body over [cubit] with the given test seams.
  Future<void> pumpRow(
    WidgetTester tester,
    BrowseSourceCubit cubit, {
    required DesktopChallengeVerifier verifier,
    Future<String?> Function(String)? solveTarget,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider.value(
            value: cubit,
            child: DesktopPopularBody(
              sourceId: _sourceId,
              sourceName: 'Manganato',
              verifier: verifier,
              solveTarget: solveTarget ?? (_) async => null,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('Cloudflare failure shows Solve Cloudflare next to Retry', (
    tester,
  ) async {
    final repo = _QueuedRepo([const CloudflareRequiredException(_challengeUrl)]);
    final cubit = BrowseSourceCubit(repo: repo, sourceId: _sourceId);
    addTearDown(cubit.close);
    await cubit.load();
    await pumpRow(tester, cubit, verifier: (_, _, _) async => false);

    expect(
      find.byKey(const ValueKey('desktop-popular-solve-cloudflare')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('desktop-popular-retry')), findsOneWidget);
    // Plain words and the site, not the raw exception text.
    expect(find.textContaining('CloudflareRequiredException'), findsNothing);
    expect(find.text('www.natomanga.com'), findsOneWidget);
  });

  testWidgets('a verified solve reloads the row with the challenged URL', (
    tester,
  ) async {
    final repo = _QueuedRepo([
      const CloudflareRequiredException(_challengeUrl),
      const <HomeSection>[HomeSection(title: 'Popular', items: [])],
    ]);
    final cubit = BrowseSourceCubit(repo: repo, sourceId: _sourceId);
    addTearDown(cubit.close);
    await cubit.load();
    final calls = <(String, String)>[];
    await pumpRow(
      tester,
      cubit,
      verifier: (_, id, url) async {
        calls.add((id, url));
        return true;
      },
    );

    await tester.tap(
      find.byKey(const ValueKey('desktop-popular-solve-cloudflare')),
    );
    await tester.pumpAndSettle();

    // The engine's challenged page is what gets verified...
    expect(calls, [(_sourceId, _challengeUrl)]);
    // ...and the failed load is retried by itself, now successfully.
    expect(repo.homeCalls, 2);
    expect(find.byKey(const ValueKey('desktop-popular-error')), findsNothing);
    expect(find.text('This source has no front page to show.'), findsOneWidget);
  });

  testWidgets('a fresh solve target wins over the reported URL', (
    tester,
  ) async {
    final repo = _QueuedRepo([const CloudflareRequiredException(_challengeUrl)]);
    final cubit = BrowseSourceCubit(repo: repo, sourceId: _sourceId);
    addTearDown(cubit.close);
    await cubit.load();
    String? verifiedUrl;
    await pumpRow(
      tester,
      cubit,
      solveTarget: (_) async => 'https://www.natomanga.com/',
      verifier: (_, _, url) async {
        verifiedUrl = url;
        return false;
      },
    );
    await tester.tap(
      find.byKey(const ValueKey('desktop-popular-solve-cloudflare')),
    );
    await tester.pumpAndSettle();
    expect(verifiedUrl, 'https://www.natomanga.com/');
  });

  testWidgets('a closed or failed verification does not reload', (
    tester,
  ) async {
    final repo = _QueuedRepo([const CloudflareRequiredException(_challengeUrl)]);
    final cubit = BrowseSourceCubit(repo: repo, sourceId: _sourceId);
    addTearDown(cubit.close);
    await cubit.load();
    await pumpRow(tester, cubit, verifier: (_, _, _) async => false);

    await tester.tap(
      find.byKey(const ValueKey('desktop-popular-solve-cloudflare')),
    );
    await tester.pumpAndSettle();

    expect(repo.homeCalls, 1);
    expect(find.byKey(const ValueKey('desktop-popular-error')), findsOneWidget);
  });

  testWidgets('an ordinary failure offers Retry only', (tester) async {
    final repo = _QueuedRepo([StateError('boom')]);
    final cubit = BrowseSourceCubit(repo: repo, sourceId: 'mihon:999');
    addTearDown(cubit.close);
    await cubit.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider.value(
            value: cubit,
            child: const DesktopPopularBody(
              sourceId: 'mihon:999',
              sourceName: 'Other',
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('desktop-popular-solve-cloudflare')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('desktop-popular-retry')), findsOneWidget);
  });
}
