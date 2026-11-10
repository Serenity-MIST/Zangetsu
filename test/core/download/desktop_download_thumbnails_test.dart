import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:watch_app/core/download/desktop_download_thumbnails.dart';

void main() {
  final engine=Platform.environment['ZANGETSU_TEST_FFMPEG'];
  test('saved video yields cached JPEG without modifying media', () async {
    final root=await Directory.systemTemp.createTemp('offline-art-');
    try {
      final media=File('${root.path}/episode.mkv');
      final generated=await Process.run(engine!,['-nostdin','-hide_banner','-loglevel','error',
        '-f','lavfi','-i','color=c=blue:s=160x96:r=12:d=1','-c:v','mpeg4',media.path]);
      expect(generated.exitCode,0,reason:'${generated.stderr}');
      final before=sha256.convert(await media.readAsBytes());
      final cache=Directory('${root.path}/cache');
      final extractor=DesktopDownloadThumbnails(engine:engine);
      final artwork=await extractor.ensure(media.path,cache);
      expect(artwork,isNotNull);
      final image=File.fromUri(Uri.parse(artwork!));
      final bytes=await image.readAsBytes(); expect(bytes.take(2),[255,216]);
      final modified=(await image.stat()).modified;
      expect(await extractor.ensure(media.path,cache),artwork);
      expect((await image.stat()).modified,modified);
      expect(sha256.convert(await media.readAsBytes()),before);
      expect(await extractor.ensure('${root.path}/missing.mkv',cache),isNull);
    } finally { await root.delete(recursive:true); }
  },skip: !Platform.isWindows || engine==null);
}
