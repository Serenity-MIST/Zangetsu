import 'package:dio/dio.dart';

/// Determines whether the native chunk downloader can safely split a file.
/// Unsupported HEAD requests, missing lengths and ignored Range headers retain
/// the ordinary single-stream path. Provider authentication headers are kept.
/// With a rate-limit policy, zero means stop instead of starting another request.
Future<int> directFileConnections(
  Dio client,
  String url,
  Map<String, String> headers,
  int requested, {
  Future<void> Function(Uri url, String? retryAfter)? onRateLimited,
}) async {
  final count = requested.clamp(1, 8);
  if (count == 1 || headers.keys.any((key) => key.toLowerCase() == 'range')) {
    return 1;
  }
  final token = CancelToken();
  try {
    final head = await client
        .head<void>(
          url,
          options: Options(
            headers: headers,
            sendTimeout: const Duration(seconds: 5),
            receiveTimeout: const Duration(seconds: 5),
          ),
          cancelToken: token,
        )
        .timeout(const Duration(seconds: 6));
    if (head.statusCode == 429 && onRateLimited != null) {
      await onRateLimited(head.realUri, head.headers.value('retry-after'));
      return 0;
    }
    final length = int.tryParse(head.headers.value('content-length') ?? '');
    if (head.statusCode != 200 ||
        length == null ||
        length < count ||
        head.headers.value('accept-ranges')?.toLowerCase() != 'bytes' ||
        (head.headers.value('content-encoding') ?? 'identity') != 'identity') {
      return 1;
    }
    // Some hosts advertise ranges but return the entire file for every range.
    // Inspect streaming response headers and close it without buffering video.
    final probe = await client
        .get<ResponseBody>(
          url,
          options: Options(
            headers: {...headers, 'Range': 'bytes=0-0'},
            responseType: ResponseType.stream,
            sendTimeout: const Duration(seconds: 5),
            receiveTimeout: const Duration(seconds: 5),
          ),
          cancelToken: token,
        )
        .timeout(const Duration(seconds: 6));
    await probe.data?.stream.listen((_) {}).cancel();
    if (probe.statusCode == 429 && onRateLimited != null) {
      await onRateLimited(probe.realUri, probe.headers.value('retry-after'));
      return 0;
    }
    return probe.statusCode == 206 &&
            probe.headers.value('content-range') == 'bytes 0-0/$length' &&
            probe.headers.value('content-length') == '1'
        ? count
        : 1;
  } on DioException catch (error) {
    final response = error.response;
    if (response?.statusCode == 429 && onRateLimited != null) {
      await onRateLimited(response!.realUri, response.headers.value('retry-after'));
      return 0;
    }
    return 1;
  } catch (_) {
    return 1;
  } finally {
    token.cancel('Range capability check finished');
  }
}
