import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/discord/discord_gateway.dart';
import 'package:watch_app/core/discord/discord_presence.dart';

void main() {
  group('discordIdentifyPayload', () {
    // Windows OAuth shape: intents present, no Discord-client-only fields.
    test('oauth shape sends intents and drops client-only fields', () {
      final p = discordIdentifyPayload('Bearer abc', oauthShape: true);
      expect(p['op'], 2);
      final d = p['d'] as Map<String, dynamic>;
      expect(d['token'], 'Bearer abc');
      expect(d['intents'], 0);
      expect(d.containsKey('capabilities'), isFalse);
      expect(d.containsKey('presence'), isFalse);
      expect(d['compress'], false);
      final props = d['properties'] as Map<String, dynamic>;
      expect(props['os'], 'windows');
      expect(props['browser'], isNot('Discord Android'));
      // Must stay valid JSON well under the 4096 byte frame limit.
      expect(jsonEncode(p).length, lessThan(4096));
    });

    // The Bearer prefix is added once and never doubled.
    test('bearer prefix is added once', () {
      expect(discordBearer('abc'), 'Bearer abc');
      expect(discordBearer('Bearer abc'), 'Bearer abc');
      final d = discordIdentifyPayload('abc', oauthShape: true)['d'] as Map;
      expect(d['token'], 'Bearer abc');
    });

    // Non-Windows platforms keep the original payload exactly.
    test('legacy shape is unchanged', () {
      final d = discordIdentifyPayload('Bearer abc', oauthShape: false)['d']
          as Map<String, dynamic>;
      expect(d['capabilities'], 0);
      expect(d.containsKey('intents'), isFalse);
      expect((d['properties'] as Map)['browser'], 'Discord Android');
      expect(d['presence'], isA<Map>());
    });
  });

  group('discordSanitizePresenceUpdate', () {
    Map<String, dynamic> first(Map<String, dynamic> d) =>
        (d['activities'] as List).first as Map<String, dynamic>;

    // Blank lines go, long lines are cut, a blank name gets a fallback.
    test('drops blank text and caps long text', () {
      final out = discordSanitizePresenceUpdate({
        'since': null,
        'status': 'online',
        'afk': false,
        'activities': [
          {
            'name': '  ',
            'type': 3,
            'details': '',
            'state': 'x' * 200,
            'assets': {'large_image': 'mp:external/a', 'large_text': ' '},
          },
        ],
      });
      final a = first(out);
      expect(a['name'], 'Zangetsu');
      expect(a.containsKey('details'), isFalse);
      expect((a['state'] as String).length, 128);
      expect(a['assets'], {'large_image': 'mp:external/a'});
    });

    // Timestamps become integers; invalid buttons are removed.
    test('fixes timestamps and buttons', () {
      final out = discordSanitizePresenceUpdate({
        'activities': [
          {
            'name': 'ONE PIECE',
            'type': 3,
            'timestamps': {'start': 1700000000000.7, 'end': 'soon'},
            'buttons': ['Open', ''],
            'metadata': {
              'button_urls': ['https://example.com', 'https://x.y'],
            },
          },
        ],
      });
      final a = first(out);
      expect(a['timestamps'], {'start': 1700000000000});
      expect(a['buttons'], ['Open']);
      expect(a['metadata'], {
        'button_urls': ['https://example.com'],
      });
    });

    // A clear (no activities) passes through untouched.
    test('clear stays a clear', () {
      final d = discordPresenceUpdate(null, '1');
      expect(discordSanitizePresenceUpdate(d)['activities'], isEmpty);
    });
  });
}
