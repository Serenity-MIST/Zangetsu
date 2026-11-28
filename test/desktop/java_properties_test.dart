import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/java_properties.dart';

/// Protects unrelated extension settings during a provider-specific reset.
void main() {
  test('removes exactly the requested namespace and preserves other bytes', () {
    const input = '# comment\r\nCine/key=s:one\r\nCineExtra/key=s:two\r\nOther/key=s:three\r\n';
    final result = removeJavaPropertyNamespace(input, 'Cine');
    expect(result.removed, 1);
    expect(result.text, '# comment\r\nCineExtra/key=s:two\r\nOther/key=s:three\r\n');
  });
  test('recognizes escaped spaces, separators and Unicode provider names', () {
    const input = r'My\ Source\:/token=s:secret' '\n' r'\u732B/key=s:value' '\n';
    final first = removeJavaPropertyNamespace(input, 'My Source:');
    expect(first.removed, 1);
    expect(removeJavaPropertyNamespace(first.text, '猫').text, '');
  });
  test('removes whole continued entries and preserves unrelated continuations', () {
    const input = 'Target/key=s:first\\\n  continued\nOther/key=s:first\\\n  preserved\n';
    final result = removeJavaPropertyNamespace(input, 'Target');
    expect(result.removed, 1);
    expect(result.text, 'Other/key=s:first\\\n  preserved\n');
  });
  test('fails before writing when a Unicode key is malformed', () {
    expect(() => removeJavaPropertyNamespace(r'\uZZZZ/key=value', 'Target'),
        throwsFormatException);
  });
}
