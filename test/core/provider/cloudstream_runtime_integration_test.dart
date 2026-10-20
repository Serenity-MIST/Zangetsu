import 'dart:io';
import 'dart:typed_data';
import 'package:cs3_engine/cs3_engine.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/desktop/cloudstream_catalog.dart';
import 'package:watch_app/core/desktop/cloudstream_runtime.dart';

class _PluginDownload implements HttpClientAdapter {
  _PluginDownload(this.bytes);
  final List<int> bytes;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async => ResponseBody.fromBytes(
    options.path.contains('broken') ? [0, 1, 2, 3] : bytes,
    200,
  );
  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'CS3 install, restart, details, failed update and repo-scoped uninstall',
    () async {
      // Use this checkout's fixtures and a private temporary data directory;
      // the old test depended on a previous workstation folder arrangement.
      final work = Directory.current.absolute.path;
      final temp = await Directory.systemTemp.createTemp('cs3-integration-');
      final fixture = File(
        '$work/packages/cs3_engine/engine/test-fixtures/SkyStreamTest.cs3',
      );
      Hive.init(temp.path);
      final dio = Dio()
        ..httpClientAdapter = _PluginDownload(await fixture.readAsBytes());
      DesktopCloudStream runtime() => DesktopCloudStream(
        dataDirectory: temp,
        repositoryClient: CloudStreamCatalog(client: dio),
        engineFactory: (path) => Cs3Engine.start(
          dataDir: path,
          java: Platform.environment['ZANGETSU_TEST_JAVA'] ??
              '$work/outputs/Zangetsu-Windows-upstream-update/extension-engine/runtime/bin/javaw.exe',
          assetsDirectory: '$work/packages/cs3_engine/assets',
        ),
      );
      var host = runtime();
      addTearDown(() async {
        await host.dispose();
        await Hive.close();
        await temp.delete(recursive: true);
      });
      const request = {
        'url': 'https://test.example/Test.cs3',
        'internalName': 'Test',
        'version': 1,
        'repoUrl': 'https://one.example/repo.json',
      };
      final installed = await host.call('installPlugin', request) as List;
      expect(installed, hasLength(2));
      final key =
          '${installed.first['sourcePlugin']}\u0001${installed.first['name']}';
      expect(await host.call('liveMainUrl', {'name': key}),
          'https://skystream.invalid');
      final detail = await host.call('load', {
        'name': key,
        'url': 'https://skystream.invalid/anime/rich',
        'category': 'sub',
      });
      expect(detail['name'], 'Rich Title');
      expect(detail['episodes'], hasLength(3));
      // A reset removes only this provider's preferences and restarts the real
      // JVM without losing the installed plugin or another provider's state.
      final preferences = File('${temp.path}/shared_prefs/rebuild_preference.properties');
      await preferences.parent.create(recursive: true);
      final providerName = '${installed.first['name']}'.replaceAll(' ', r'\ ');
      await preferences.writeAsString('$providerName/test=s:reset-me\nOther/test=s:keep-me\n');
      expect(await host.call('resetPluginData', {'name': key}), isTrue);
      expect(await preferences.readAsString(), 'Other/test=s:keep-me\n');
      expect((await host.call('load', {
        'name': key, 'url': 'https://skystream.invalid/anime/rich',
      }))['name'], 'Rich Title');
      await host.dispose();
      await Hive.close();
      host = runtime();
      expect(await host.call('listSources'), hasLength(2));
      final restored = await host.call('load', {
        'name': key,
        'url': 'https://skystream.invalid/anime/rich',
      });
      expect(restored['syncData']['mal'], '52991');
      await expectLater(
        host.call('updatePlugin', {
          ...request,
          'version': 2,
          'url': 'https://test.example/broken.cs3',
        }),
        throwsFormatException,
      );
      expect(await host.call('listSources'), hasLength(2));
      await host.call('installPlugin', {
        ...request,
        'repoUrl': 'https://two.example/repo.json',
      });
      expect(await host.call('listSources'), hasLength(4));
      await host.call('uninstallPlugin', request);
      final remaining = await host.call('listSources') as List;
      expect(remaining, hasLength(2));
      expect(
        remaining.first['sourcePlugin'],
        contains(DesktopCloudStream.repoTag('https://two.example/repo.json')),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
