import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:watch_app/core/download/direct_file_connections.dart';

/// Isolates the real desktop downloader's metadata and temporary storage.
class _FixturePaths extends PathProviderPlatform {
  _FixturePaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

/// Avoids the storage plugin's separate engine isolate in flutter_tester while
/// retaining the actual desktop HTTP/chunk workers and pause-resume data.
class _MemoryStorage implements PersistentStorage {
  final paused = <String, Task>{};
  final resumeData = <String, ResumeData>{};
  final records = <String, TaskRecord>{};
  @override
  (String, int) get currentDatabaseVersion => ('fixture', 1);
  @override
  Future<(String, int)> get storedDatabaseVersion async =>
      currentDatabaseVersion;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> storeTaskRecord(TaskRecord record) async {
    records[record.task.taskId] = record;
  }

  @override
  Future<TaskRecord?> retrieveTaskRecord(String id) async => records[id];
  @override
  Future<List<TaskRecord>> retrieveAllTaskRecords() async =>
      records.values.toList();
  @override
  Future<void> removeTaskRecord(String? id) async {
    id == null ? records.clear() : records.remove(id);
  }

  @override
  Future<void> storePausedTask(Task task) async {
    paused[task.taskId] = task;
  }

  @override
  Future<Task?> retrievePausedTask(String id) async => paused[id];
  @override
  Future<List<Task>> retrieveAllPausedTasks() async => paused.values.toList();
  @override
  Future<void> removePausedTask(String? id) async {
    id == null ? paused.clear() : paused.remove(id);
  }

  @override
  Future<void> storeResumeData(ResumeData data) async {
    resumeData[data.task.taskId] = data;
  }

  @override
  Future<ResumeData?> retrieveResumeData(String id) async => resumeData[id];
  @override
  Future<List<ResumeData>> retrieveAllResumeData() async =>
      resumeData.values.toList();
  @override
  Future<void> removeResumeData(String? id) async {
    id == null ? resumeData.clear() : resumeData.remove(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real desktop eight-chunk transfer preserves every byte',
    () async {
      // Flutter tests otherwise default to Android, selecting its channel backend.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      // This fixture intentionally uses loopback HTTP, not Flutter's default400.
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = null;
      final root = await Directory.systemTemp.createTemp('range-integrity-');
      final previousPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FixturePaths(root.path);
      final bytes = Uint8List.fromList(
        List.generate(2 * 1024 * 1024, (i) => (i * 31 + i ~/ 251) % 256),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final ranges = <String>[];
      final requests = server.listen((request) async {
        final response = request.response;
        response.headers.set('accept-ranges', 'bytes');
        response.headers.contentType = ContentType.binary;
        if (request.headers.value('x-fixture') != 'allowed') {
          response.statusCode = 403;
          await response.close();
          return;
        }
        final range = request.headers.value('range');
        var first = 0;
        var last = bytes.length - 1;
        if (range != null) {
          ranges.add(range);
          final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range)!;
          first = int.parse(match[1]!);
          if (match[2]!.isNotEmpty) last = int.parse(match[2]!);
          response.statusCode = 206;
          response.headers.set(
            'content-range',
            'bytes $first-$last/${bytes.length}',
          );
        }
        response.contentLength = last - first + 1;
        if (request.method != 'HEAD') {
          response.add(bytes.sublist(first, last + 1));
        }
        await response.close();
      });
      final client = Dio();
      final downloader = FileDownloader(persistentStorage: _MemoryStorage());
      try {
        await downloader.ready.timeout(const Duration(seconds: 5));
        final url = 'http://127.0.0.1:${server.port}/fixture.mp4';
        const headers = {'x-fixture': 'allowed'};
        final connections = await directFileConnections(
          client,
          url,
          headers,
          8,
        );
        expect(connections, 8);
        final task = ParallelDownloadTask(
          url: url,
          chunks: connections,
          directory: root.path,
          baseDirectory: BaseDirectory.root,
          filename: 'result.mp4',
          headers: headers,
          updates: Updates.statusAndProgress,
        );
        final result = await downloader
            .download(task)
            .timeout(const Duration(seconds: 30));
        expect(
          result.status,
          TaskStatus.complete,
          reason: '${result.exception}',
        );
        expect(
          await File('${root.path}/result.mp4').readAsBytes(),
          orderedEquals(bytes),
        );
        // One capability probe plus eight actual non-overlapping chunk requests.
        expect(ranges.where((range) => range != 'bytes=0-0'), hasLength(8));
      } finally {
        client.close(force: true);
        await downloader.reset();
        await downloader.reset(group: FileDownloader.chunkGroup);
        await server.close(force: true);
        await requests.cancel();
        PathProviderPlatform.instance = previousPaths;
        debugDefaultTargetPlatformOverride = null;
        HttpOverrides.global = previousHttp;
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows
        ? 'Windows desktop backend only'
        : !const bool.fromEnvironment('RUN_DESKTOP_HTTP_INTEGRATION')
        ? 'Requires full desktop engine: flutter_tester worker raises Dart VM callback prohibition; see merge-work/windows-download-connections.json'
        : false,
  );
}
