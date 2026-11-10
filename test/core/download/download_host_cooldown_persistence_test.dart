import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/download/download_prefs.dart';
void main() {
  test('host cooldown survives Hive reopen without storing private URLs', () async {
    final root = await Directory.systemTemp.createTemp('zangetsu-cooldown-');
    Hive.init(root.path);
    try {
      await Hive.openBox(DownloadPrefs.boxName);
      final now = DateTime.utc(2026);
      final url = Uri.parse('https://cdn.test/file?token=secret');
      final prefs = DownloadPrefs();
      await prefs.rememberHostCooldown(url, '120', now: now);
      await prefs.rememberHostCooldown(url, '1', now: now);
      final deadline = now.add(const Duration(seconds: 120));
      expect(prefs.hostCooldownUntil(url, now: now), deadline);
      expect(prefs.hostCooldownUntil(Uri.parse('https://other.test/file'), now: now), isNull);
      expect(Hive.box(DownloadPrefs.boxName).keys, ['windowsHostCooldown:cdn.test']);
      await Hive.close();
      await Hive.openBox(DownloadPrefs.boxName);
      expect(DownloadPrefs().hostCooldownUntil(url, now: now), deadline);
      expect(prefs.hostCooldownUntil(url, now: deadline), isNull);
      await Hive.box(DownloadPrefs.boxName).put('windowsHostCooldown:cdn.test', 'corrupt');
      expect(prefs.hostCooldownUntil(url, now: now), isNull);
      expect(await prefs.rememberHostCooldown(Uri.parse('file:///local'), '120'), isNull);
    } finally {
      await Hive.close();
      await root.delete(recursive: true);
    }
  });
}
