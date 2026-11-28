// shell-1: the hook Profile uses to open Settings through the shell (a full
// page over the rail). With
// no shell handler installed it must report false so the caller pushes the
// Settings route instead.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_settings_opener.dart';

void main() {
  tearDown(() => DesktopSettingsOpener.handler = null);

  test('open reports false when no shell handler is installed', () {
    DesktopSettingsOpener.handler = null;
    expect(DesktopSettingsOpener.open(), isFalse);
  });

  test('open runs the installed shell handler', () {
    var opened = 0;
    DesktopSettingsOpener.handler = () => opened++;
    expect(DesktopSettingsOpener.open(), isTrue);
    expect(opened, 1);
  });
}
