import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/features/player/player_controller.dart';
import 'package:watch_app/features/player/player_controls_config.dart';
import 'package:watch_app/features/player/player_screen.dart';
import 'package:watch_app/features/player/shader_presets.dart';

/// Pure checks behind the Windows Playback settings: each one is the logic a
/// setting relies on to change what the PC player does.
void main() {
  group('Video decoder reaches mpv on the first open', () {
    test('Windows and Apple pass the user decoder at creation', () {
      expect(configHwdecFor(DecoderPlatform.windows, () => 'no'), 'no');
      expect(
        configHwdecFor(DecoderPlatform.apple, () => 'videotoolbox-copy'),
        'videotoolbox-copy',
      );
    });

    test('Android keeps media_kit default (emulator fallback)', () {
      var read = false;
      expect(
        configHwdecFor(DecoderPlatform.android, () {
          read = true;
          return 'mediacodec-copy';
        }),
        isNull,
      );
      expect(read, isFalse);
    });

    test('every Windows choice maps to a d3d11/CPU hwdec', () {
      String map(String c) => resolveHwdec(
        choice: c,
        videoOutput: 'auto',
        platform: DecoderPlatform.windows,
      );
      expect(map('copy'), 'd3d11va-copy');
      expect(map('direct'), 'd3d11va');
      expect(map('sw'), 'no');
      expect(map('auto'), 'auto-safe');
      // The PC labels cover exactly the stored ids.
      expect(kWindowsDecoderOptions.map((o) => o.$1), [
        'copy',
        'direct',
        'sw',
        'auto',
      ]);
    });
  });

  group('Anime4K on Windows', () {
    test('shader list uses the Windows path separator', () {
      const paths = [r'C:\a\Clamp.glsl', r'C:\a\Up.glsl'];
      expect(
        ShaderPresets.joinShaderPaths(paths, windows: true),
        r'C:\a\Clamp.glsl;C:\a\Up.glsl',
      );
      expect(
        ShaderPresets.joinShaderPaths(['/a/x.glsl', '/a/y.glsl'], windows: false),
        '/a/x.glsl:/a/y.glsl',
      );
    });

    test('only video-output shader errors trigger the fallback', () {
      expect(
        isShaderFailureLog('vo/libmpv', 'error', 'Failed to open shader file'),
        isTrue,
      );
      expect(
        isShaderFailureLog('vo/gpu', 'error', 'GLSL compile failed'),
        isTrue,
      );
      expect(
        isShaderFailureLog('vo/libmpv', 'fatal', 'Failed rendering frame!'),
        isTrue,
      );
      // Not an error, not the renderer, or not about shaders: ignored.
      expect(
        isShaderFailureLog('vo/libmpv', 'warn', 'shader cache miss'),
        isFalse,
      );
      expect(
        isShaderFailureLog('ffmpeg', 'error', 'tcp: shader.example timeout'),
        isFalse,
      );
      expect(
        isShaderFailureLog('vo/libmpv', 'error', 'Could not create device'),
        isFalse,
      );
    });
  });

  group('Next-episode preload', () {
    test('starts 5 minutes before the end of a normal episode', () {
      expect(
        nextEpisodePrefetchAt(const Duration(minutes: 24)),
        const Duration(minutes: 19),
      );
      // A 2 h movie starts at 85% (sooner than 5 min before the end).
      expect(
        nextEpisodePrefetchAt(const Duration(minutes: 120)),
        const Duration(minutes: 102),
      );
    });

    test('short videos never start before a quarter', () {
      // 6 min: "5 min left" would be 1:00, the quarter floor holds it at 1:30.
      expect(
        nextEpisodePrefetchAt(const Duration(minutes: 6)),
        const Duration(seconds: 90),
      );
      expect(
        nextEpisodePrefetchAt(const Duration(minutes: 2)),
        const Duration(seconds: 30),
      );
    });
  });

  group('Player controls on Windows', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('Cast and PiP are unavailable only on Windows', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(unavailablePlayerControls(), {'cast', 'pip'});
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(unavailablePlayerControls(), isEmpty);
    });

    test('Windows defaults do not spend a top slot on Cast', () {
      final cfg = PlayerControlsConfig.defaults.sanitised(
        unavailable: kWindowsUnavailableControls,
      );
      expect(cfg.top, ['info']);
      expect(cfg.hidden, isNot(contains('cast')));
      expect(cfg.hidden, isNot(contains('pip')));
      // Phone unchanged.
      expect(PlayerControlsConfig.defaults.sanitised().top, ['cast', 'info']);
      expect(PlayerControlsConfig.defaults.sanitised().hidden, contains('pip'));
    });

    test('the top cap counts only controls that render', () {
      const saved = PlayerControlsConfig(
        top: ['cast', 'info', 'speed', 'tracks', 'quality', 'sources'],
        left: ['more', 'pip'],
        right: [],
      );
      final cfg = saved.sanitised(unavailable: kWindowsUnavailableControls);
      expect(cfg.top, ['info', 'speed', 'tracks', 'quality', 'sources']);
      expect(cfg.left, ['more']);
    });
  });

  group('Player opens in (Windows orientation pref)', () {
    test('Windows opens the watch page for every stored value', () {
      for (final v in ['portrait', 'landscape', 'system']) {
        for (final wide in [true, false]) {
          expect(
            initialPresentation(
              isTv: false,
              orientation: v,
              isLandscape: wide,
              windows: true,
            ),
            PlayerPresentation.watchPage,
            reason: '$v wide=$wide',
          );
        }
      }
    });

    test('phone still follows the stored value', () {
      PlayerPresentation open(String v, {bool wide = true}) =>
          initialPresentation(isTv: false, orientation: v, isLandscape: wide);
      expect(open('portrait'), PlayerPresentation.watchPage);
      expect(open('landscape'), PlayerPresentation.fullscreen);
      expect(open('system'), PlayerPresentation.fullscreen);
      expect(open('system', wide: false), PlayerPresentation.watchPage);
    });

    test('labels name the layout, not a rotation', () {
      expect(windowsPlayerOpensInLabel('portrait'), 'Watch page');
      expect(windowsPlayerOpensInLabel('landscape'), 'Full window');
      expect(windowsPlayerOpensInLabel('system'), 'Match window shape');
      expect(
        kWindowsPlayerOpensInOptions.map((o) => o.$1),
        ['portrait', 'landscape'],
      );
    });

    test('close confirmation wording names Esc / Back', () {
      expect(windowsCloseConfirmLabel('double_back'), contains('Esc'));
      expect(windowsCloseConfirmLabel('direct'), 'Close at once');
      expect(windowsCloseConfirmLabel('bogus'), contains('twice'));
    });
  });
}
