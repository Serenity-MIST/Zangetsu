import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/lnreader/novel_cloudflare.dart';

void main() {
  tearDown(NovelCloudflare.clear);
  test('selected site receives its own pending challenge', () {
    NovelCloudflare.needsSolve('https://novel.example/challenge');
    expect(
      NovelCloudflare.pendingForSite('https://novel.example/'),
      'https://novel.example/challenge',
    );
  });
  test('unrelated and suffix-lookalike sites cannot borrow a challenge', () {
    NovelCloudflare.needsSolve('https://novel.example/challenge');
    expect(NovelCloudflare.pendingForSite('https://other.example'), isNull);
    expect(
      NovelCloudflare.pendingForSite('https://novel.example.evil'),
      isNull,
    );
  });
  test('invalid or non-web pending URLs are ignored', () {
    NovelCloudflare.needsSolve('file:///novel.example');
    expect(NovelCloudflare.pendingForSite('https://novel.example'), isNull);
    NovelCloudflare.needsSolve('https://novel.example/challenge');
    expect(NovelCloudflare.pendingForSite('not a website'), isNull);
  });
  test('clearing removes selected-site challenge', () {
    NovelCloudflare.needsSolve('https://novel.example/challenge');
    NovelCloudflare.clear();
    expect(NovelCloudflare.pendingForSite('https://novel.example'), isNull);
  });
}
