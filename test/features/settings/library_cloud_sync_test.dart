import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/settings/library_cloud_sync.dart';

void main() {
  test(
    'uploads watch, reading and list stores and retains partial failures',
    () async {
      final calls = <String>[];
      final result = await uploadLibraryStores([
        () async {
          calls.add('watch');
          return (pushed: 2, failed: 0);
        },
        () async {
          calls.add('read');
          return (pushed: 3, failed: 1);
        },
        () async {
          calls.add('list');
          return (pushed: 4, failed: 0);
        },
      ]);
      expect(calls, ['watch', 'read', 'list']);
      expect(result, (pushed: 9, failed: 1));
    },
  );

  test('a failed store does not prevent remaining stores uploading', () async {
    var remainingCalled = false;
    final result = await uploadLibraryStores([
      () async => throw StateError('server unavailable'),
      () async {
        remainingCalled = true;
        return (pushed: 2, failed: 0);
      },
    ]);
    expect(remainingCalled, isTrue);
    expect(result, (pushed: 2, failed: 1));
  });
}
