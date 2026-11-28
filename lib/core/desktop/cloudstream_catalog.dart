import 'dart:convert';
import 'package:dio/dio.dart';
import '../provider/cs_repo_url.dart';

const megixRepoUrl =
    'https://raw.githubusercontent.com/SaurabhKaperwan/CSX/builds/CS.json';

/// Reads standard repository manifests and merges their referenced CS3 lists.
/// Relative URLs are resolved against their manifest/list before installation.
class CloudStreamCatalog {
  CloudStreamCatalog({Dio? client})
    : client =
          client ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 30),
            ),
          );
  final Dio client;

  /// Resolves an address and rejects non-HTTP schemes before fetching it.
  static Uri httpUri(String value, [Uri? base]) {
    final uri = base == null ? Uri.parse(value) : base.resolve(value);
    if (!{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty) {
      throw const FormatException('Enter a valid CloudStream repository URL.');
    }
    return uri;
  }

  /// Decodes repository JSON as text, independent of server Content-Type.
  Future<dynamic> _read(Uri uri) async {
    final response = await client.getUri(
      uri,
      options: Options(responseType: ResponseType.plain),
    );
    return jsonDecode(response.data as String);
  }

  /// Fetches every plugin list, keeping the highest version of each internal name.
  /// Throws FormatException for manifests or lists with unsupported shapes.
  Future<Map<String, dynamic>> fetch(String input) async {
    final uri = httpUri(normalizeCsRepoUrl(input));
    final manifest = await _read(uri);
    if (manifest is! Map || manifest['pluginLists'] is! List) {
      throw const FormatException(
        'This URL is not a CloudStream repository manifest.',
      );
    }
    final plugins = <String, Map<String, dynamic>>{};
    for (final address in manifest['pluginLists'] as List) {
      final listUri = httpUri('$address', uri);
      final entries = await _read(listUri);
      if (entries is! List)
        throw const FormatException('Invalid CloudStream plugin list.');
      for (final entry in entries) {
        if (entry is! Map) continue;
        final item = Map<String, dynamic>.from(entry);
        final name = '${item['internalName'] ?? item['name'] ?? ''}';
        if (name.isEmpty || item['url'] is! String) continue;
        item['internalName'] = name;
        item['name'] ??= name;
        item['url'] = httpUri(item['url'] as String, listUri).toString();
        item['version'] = int.tryParse('${item['version']}') ?? 1;
        if ((plugins[name]?['version'] as int? ?? -1) <=
            (item['version'] as int))
          plugins[name] = item;
      }
    }
    return {
      'url': uri.toString(),
      'name': manifest['name'] ?? uri.host,
      'plugins': plugins.values.toList(),
    };
  }
}
