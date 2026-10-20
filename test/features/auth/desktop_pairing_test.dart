import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/features/auth/tv_pair_screen.dart';
import 'package:watch_app/features/auth/tv_tracker_connect_screen.dart';
import 'package:watch_app/features/auth/tv_pairing_service.dart';
import 'package:watch_app/l10n/app_localizations.dart';

class PairingFake implements TvPairingService {
  int starts = 0;
  bool expired = false;
  @override
  Future<({String code, String tvSecret, String nonce})> startPairing(
    String deviceName,
  ) async {
    starts++;
    return (code: 'ABCD1234', tvSecret: 'local-secret', nonce: 'nonce');
  }

  @override
  Future<PairPoll> poll(String code, String tvSecret) async =>
      expired ? const PairPoll.expired() : const PairPoll.pending();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late PairingFake service;
  setUp(() {
    service = PairingFake();
    sl.registerSingleton<TvPairingService>(service);
  });
  tearDown(() async => sl.reset());
  Widget app(Widget screen) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: screen,
  );
  testWidgets('all-account transfer shows a single QR', (tester) async {
    await tester.pumpWidget(app(const TvTrackerConnectScreen()));
    await tester.pump();
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('Connect all accounts'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  for (final width in [600.0, 1366.0]) {
    testWidgets('phone login QR fits a $width wide desktop window', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app(const TvPairScreen()));
      await tester.pump();
      expect(find.byType(QrImageView), findsOneWidget);
      expect(service.starts, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
    'tracker QR starts after localization and can renew an expired code',
    (tester) async {
      await tester.pumpWidget(
        app(const TvTrackerConnectScreen(trackerId: 'anilist')),
      );
      await tester.pump();
      expect(find.byType(QrImageView), findsNWidgets(2));
      expect(service.starts, 1);
      expect(tester.takeException(), isNull);
      service.expired = true;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.text('Get a new code'), findsOneWidget);
      service.expired = false;
      await tester.tap(find.text('Get a new code'));
      await tester.pump();
      expect(service.starts, 2);
      expect(find.byType(QrImageView), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
