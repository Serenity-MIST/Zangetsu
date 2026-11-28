import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/desktop_dash_downloader.dart';

/// Video only (no audio set), 60 seconds long.
const _mpd = '''<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static"
     mediaPresentationDuration="PT60S">
  <Period id="0">
    <AdaptationSet contentType="video" mimeType="video/mp4">
      <Representation id="v720" bandwidth="1500000" width="1280" height="720"/>
    </AdaptationSet>
  </Period>
</MPD>''';

/// A stand-in for ffmpeg (a Windows batch file). Each run adds a line to
/// runs.txt. Run N exits with an error, like a dropped connection, when a
/// file failN.txt exists; the others wait `pause.txt` seconds without
/// output, then report the whole length and write the output (its last
/// argument). Only cmd built-ins and System32 tools, so a Unix `find` or
/// `ping` earlier on PATH cannot get in the way.
const _fakeEngine = r'''@echo off
setlocal enabledelayedexpansion
set "out="
for %%a in (%*) do set "out=%%~a"
echo run>>"%~dp0runs.txt"
set /a n=0
if exist "%~dp0count.txt" set /p n=<"%~dp0count.txt"
set /a n+=1
>"%~dp0count.txt" echo !n!
if exist "%~dp0fail!n!.txt" exit /b 1
if exist "%~dp0pause.txt" (
  set /p wait=<"%~dp0pause.txt"
  "%SystemRoot%\System32\ping.exe" -n !wait! 127.0.0.1 >nul
)
echo out_time_us=60000000
echo total_size=4
echo saved>"!out!"
exit /b 0
''';

void main() {
  late Directory root;
  late HttpServer server;
  late Dio dio;
  late String engine;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dash-network-');
    engine = '${root.path}\\ffmpeg.cmd';
    await File(engine).writeAsString(_fakeEngine.replaceAll('\n', '\r\n'));
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.write(_mpd);
      await request.response.close();
    });
    dio = Dio();
  });

  tearDown(() async {
    dio.close(force: true);
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  Future<int> runs() async {
    final file = File('${root.path}\\runs.txt');
    if (!await file.exists()) return 0;
    return (await file.readAsLines()).where((l) => l.trim().isNotEmpty).length;
  }

  Future<String?> save(DesktopDashDownloader dash) => dash.download(
    url: 'http://127.0.0.1:${server.port}/index.mpd',
    headers: const {},
    outputPath: '${root.path}\\E1.mp4',
    quality: '720p',
    canceled: () => false,
    onProgress: (_) {},
  );

  test(
    'a run the network ended starts again once it is back',
    () async {
      await File('${root.path}\\fail1.txt').writeAsString('');
      var offline = true;
      var waited = 0;
      final dash = DesktopDashDownloader(
        executablePath: engine,
        dio: dio,
        networkDown: () {
          final down = offline;
          // The drop is noticed during the first run, then it comes back.
          offline = false;
          return down;
        },
        waitForNetwork: () async => waited++,
      );

      expect(await save(dash), isNull);
      expect(await runs(), 2);
      expect(waited, 1);
      expect(await File('${root.path}\\E1.mp4').readAsString(), contains('saved'));
      expect(await File('${root.path}\\E1.mp4.part').exists(), isFalse);
    },
    skip: !Platform.isWindows,
  );

  test(
    'a failed run with the network up is not repeated',
    () async {
      await File('${root.path}\\fail1.txt').writeAsString('');
      final dash = DesktopDashDownloader(
        executablePath: engine,
        dio: dio,
        networkDown: () => false,
        waitForNetwork: () async {},
      );

      expect(await save(dash), 'This DASH stream could not be saved');
      expect(await runs(), 1);
    },
    skip: !Platform.isWindows,
  );

  test(
    'time offline is not counted as a stall',
    () async {
      // No output for about 2 seconds, with a 300 ms stall limit.
      await File('${root.path}\\pause.txt').writeAsString('3');
      final dash = DesktopDashDownloader(
        executablePath: engine,
        dio: dio,
        networkDown: () => true,
        waitForNetwork: () async {},
        stallLimit: const Duration(milliseconds: 300),
      );

      expect(await save(dash), isNull);
      expect(await runs(), 1);
    },
    skip: !Platform.isWindows,
  );

  test(
    'with the network up the same silence is a stall',
    () async {
      await File('${root.path}\\pause.txt').writeAsString('2');
      final dash = DesktopDashDownloader(
        executablePath: engine,
        dio: dio,
        networkDown: () => false,
        waitForNetwork: () async {},
        stallLimit: const Duration(milliseconds: 300),
      );

      // A stall counts as a network-type end, so it is started again (up to
      // the limit) and every run stalls the same way.
      expect(await save(dash), 'The download stopped receiving data');
      expect(await runs(), DesktopDashDownloader.networkRetries + 1);
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
