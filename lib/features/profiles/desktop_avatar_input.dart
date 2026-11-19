import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/desktop/desktop_clipboard_image.dart';
import '../../core/desktop/desktop_context_menu.dart';
import '../../core/desktop/desktop_drop_target.dart';
import '../../core/desktop/desktop_native.dart';
import '../../core/desktop/desktop_window.dart';
import '../../core/di/injector.dart';
import '../../core/profiles/profile_avatar_uploader.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/desktop_docked_panel.dart';
import '../../l10n/l10n.dart';

/// Windows avatar input (acct-6): instead of a phone bottom sheet, avatars
/// offer a small menu anchored to the avatar and accept dropped or pasted
/// images. Phone screens never call into this file.

/// The rows of the avatar menu.
enum DesktopAvatarAction { uploadImage, uploadGif, searchGifs }

/// Opens the avatar menu below [anchor] (the avatar or its button).
/// [searchGifs] hides the GIF search row where it is not offered.
Future<DesktopAvatarAction?> showDesktopAvatarMenu(
  BuildContext context, {
  required BuildContext anchor,
  bool searchGifs = true,
}) => showDesktopContextMenu<DesktopAvatarAction>(
  context,
  anchor: anchor,
  items: [
    DesktopMenuItem(
      label: context.l10n.uploadImageEllipsis,
      icon: Icons.image_outlined,
      value: DesktopAvatarAction.uploadImage,
    ),
    DesktopMenuItem(
      label: context.l10n.uploadGifEllipsis,
      icon: Icons.movie_filter_outlined,
      value: DesktopAvatarAction.uploadGif,
    ),
    if (searchGifs)
      DesktopMenuItem(
        label: context.l10n.searchGifsEllipsis,
        icon: Icons.search_rounded,
        value: DesktopAvatarAction.searchGifs,
      ),
  ],
);

/// File extensions accepted when an image is dropped or pasted.
const desktopAvatarImageExtensions = {
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'bmp',
};

/// Largest still image read from a drop or paste; the uploader shrinks it
/// to avatar size afterwards. (GIFs use the uploader's own GIF limit.)
const int desktopAvatarMaxStillBytes = 20 * 1024 * 1024;

/// Result of reading a dropped or pasted image: either bytes for the
/// uploader or a message to show the user.
class DesktopAvatarFile {
  const DesktopAvatarFile.bytes(Uint8List this.bytes) : error = null;
  const DesktopAvatarFile.error(String this.error) : bytes = null;

  final Uint8List? bytes;
  final String? error;
}

/// True when [bytes] start with a GIF signature.
bool desktopAvatarLooksLikeGif(Uint8List bytes) =>
    bytes.length >= 6 &&
    bytes[0] == 0x47 && // G
    bytes[1] == 0x49 && // I
    bytes[2] == 0x46 && // F
    bytes[3] == 0x38; // 8

/// Checks size limits for in-memory image bytes (pasted pictures, downloads).
DesktopAvatarFile desktopAvatarCheckBytes(Uint8List bytes) {
  final gif = desktopAvatarLooksLikeGif(bytes);
  final limit = gif
      ? ProfileAvatarUploader.maxGifSourceBytes
      : desktopAvatarMaxStillBytes;
  if (bytes.length > limit) {
    // Helpers below have no context; appL10n follows the app language.
    return DesktopAvatarFile.error(
      gif
          ? appL10n.avatarGifTooLarge
          : appL10n.avatarImageTooLarge,
    );
  }
  return DesktopAvatarFile.bytes(bytes);
}

/// True when [path] has an image extension the avatar accepts.
bool desktopAvatarIsImagePath(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return false;
  return desktopAvatarImageExtensions.contains(
    path.substring(dot + 1).toLowerCase(),
  );
}

/// Reads a local image file, or returns null when [path] is not an image.
Future<DesktopAvatarFile?> readDesktopAvatarFile(String path) async {
  if (!desktopAvatarIsImagePath(path)) return null;
  try {
    final file = File(path);
    final gif = path.toLowerCase().endsWith('.gif');
    final limit = gif
        ? ProfileAvatarUploader.maxGifSourceBytes
        : desktopAvatarMaxStillBytes;
    // Check the size before reading so a huge file is never loaded.
    if (await file.length() > limit) {
      return DesktopAvatarFile.error(
        gif
            ? appL10n.avatarGifTooLarge
            : appL10n.avatarImageTooLarge,
      );
    }
    return DesktopAvatarFile.bytes(await file.readAsBytes());
  } catch (_) {
    return DesktopAvatarFile.error(
      appL10n.couldNotReadImageFile,
    );
  }
}

/// Test hook replacing the download of a dropped or pasted image link.
@visibleForTesting
Future<Uint8List?> Function(Uri url)? debugAvatarDownloadOverride;

/// Downloads an image link (dragged from a browser or pasted). Only http(s),
/// only image responses, and never more than the size limit.
Future<DesktopAvatarFile?> _downloadImage(Uri url) async {
  final override = debugAvatarDownloadOverride;
  if (override != null) {
    final bytes = await override(url);
    return bytes == null ? null : desktopAvatarCheckBytes(bytes);
  }
  if (!sl.isRegistered<Dio>()) return null;
  // Stop the download as soon as it passes the largest accepted size (the
  // still-image limit), so a huge link is never pulled into memory in full.
  final cancel = CancelToken();
  try {
    final response = await sl<Dio>().getUri<List<int>>(
      url,
      cancelToken: cancel,
      onReceiveProgress: (received, total) {
        if (received > desktopAvatarMaxStillBytes ||
            total > desktopAvatarMaxStillBytes) {
          cancel.cancel();
        }
      },
      options: Options(
        responseType: ResponseType.bytes,
        receiveTimeout: const Duration(seconds: 20),
      ),
    );
    final type = response.headers.value(Headers.contentTypeHeader) ?? '';
    final data = response.data;
    if (data == null || !type.toLowerCase().startsWith('image/')) {
      return DesktopAvatarFile.error(
        appL10n.linkIsNotImage,
      );
    }
    return desktopAvatarCheckBytes(Uint8List.fromList(data));
  } catch (_) {
    // Cancelled above because the image was over the size limit.
    if (cancel.isCancelled) {
      return DesktopAvatarFile.error(
        appL10n.avatarImageTooLarge,
      );
    }
    return DesktopAvatarFile.error(
      appL10n.couldNotDownloadImage,
    );
  }
}

/// Turns dropped or pasted text into an image: a local path, a file:// URI
/// or an http(s) link. Returns null when the text is none of those.
Future<DesktopAvatarFile?> readDesktopAvatarText(String? text) async {
  final value = text?.trim().split(RegExp(r'[\r\n]')).first.trim() ?? '';
  if (value.isEmpty) return null;
  // Explorer "Copy as path" wraps the path in quotes.
  final unquoted =
      value.length > 1 && value.startsWith('"') && value.endsWith('"')
      ? value.substring(1, value.length - 1)
      : value;
  final uri = Uri.tryParse(unquoted);
  if (uri != null && uri.scheme == 'file') {
    return readDesktopAvatarFile(uri.toFilePath(windows: true));
  }
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    return _downloadImage(uri);
  }
  return readDesktopAvatarFile(unquoted);
}

/// Picks the first usable image out of a drop: a file first, then a link.
Future<DesktopAvatarFile?> readDesktopAvatarDrop(DesktopDropEvent event) async {
  for (final path in event.paths) {
    final file = await readDesktopAvatarFile(path);
    if (file != null) return file;
  }
  if (event.paths.isNotEmpty && (event.text?.trim().isEmpty ?? true)) {
    return DesktopAvatarFile.error(
      appL10n.dropAvatarImageTypes,
    );
  }
  return readDesktopAvatarText(event.text);
}

/// Reads an image from the clipboard: copied files, a copied picture, or a
/// copied path / link as text.
Future<DesktopAvatarFile?> readDesktopAvatarClipboard() async {
  final native = await readDesktopClipboardImage();
  if (native != null) {
    for (final path in native.paths) {
      final file = await readDesktopAvatarFile(path);
      if (file != null) return file;
    }
    final bytes = native.imageBytes;
    if (bytes != null) return desktopAvatarCheckBytes(bytes);
  }
  try {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return await readDesktopAvatarText(data?.text);
  } catch (_) {
    return null;
  }
}

/// Wraps an avatar area so that on Windows an image can be dropped on it
/// from Explorer or a browser, or pasted with Ctrl+V while its page is on
/// top (and no text field is focused). Shows an accent ring while a drag
/// hovers. Off Windows it is just [child].
class DesktopAvatarDropZone extends StatefulWidget {
  const DesktopAvatarDropZone({
    super.key,
    required this.child,
    required this.onImage,
    required this.onError,
    this.enabled = true,
    this.borderRadius = const BorderRadius.all(Radius.circular(18)),
  });

  final Widget child;

  /// Image bytes (still or GIF) ready for ProfileAvatarUploader.
  final ValueChanged<Uint8List> onImage;

  /// A message for the user when a drop or paste could not be used.
  final ValueChanged<String> onError;

  /// False while an upload runs, so a second image is not started.
  final bool enabled;

  /// Shape of the hover ring.
  final BorderRadius borderRadius;

  @override
  State<DesktopAvatarDropZone> createState() => _DesktopAvatarDropZoneState();
}

class _DesktopAvatarDropZoneState extends State<DesktopAvatarDropZone> {
  bool _hovering = false;
  // Whether this zone's tab is the visible one. The shell keeps visited tabs
  // alive (IndexedStack, TickerMode off) and DesktopDropTarget only checks
  // geometry, so a hidden Profile tab must not take drops or Ctrl+V meant
  // for the page on screen. Read in build so TickerMode changes rebuild it.
  bool _tickerActive = true;
  // Remembers whether the keyboard handler was added, so dispose removes it
  // even if the platform override changes in tests.
  bool _listening = false;

  @override
  void initState() {
    super.initState();
    if (!desktopPanelsEnabled) return;
    _listening = true;
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    if (_listening) HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  // Ctrl+V pastes an image onto the avatar. Ignored inside text fields (they
  // paste text) and when another route covers this page.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.keyV ||
        !HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isShiftPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        !widget.enabled ||
        !mounted) {
      return false;
    }
    if (!_onScreen()) return false;
    if (DesktopWindow.focusInTextField()) return false;
    unawaited(_paste());
    return true;
  }

  /// True when this zone's route is on top and its tab is the visible one.
  bool _onScreen() =>
      mounted && _tickerActive && (ModalRoute.of(context)?.isCurrent ?? true);

  Future<void> _paste() async {
    final file = await readDesktopAvatarClipboard();
    if (!mounted || !widget.enabled) return;
    _deliver(
      file ??
          DesktopAvatarFile.error(
            context.l10n.copyImageFirst,
          ),
    );
  }

  Future<void> _onDrop(DesktopDropEvent event) async {
    // A drop over a hidden tab or a covered page is not meant for us.
    if (!widget.enabled || !_onScreen()) return;
    final file = await readDesktopAvatarDrop(event);
    if (!mounted || file == null || !widget.enabled) return;
    _deliver(file);
  }

  void _deliver(DesktopAvatarFile file) {
    final bytes = file.bytes;
    if (bytes != null) {
      widget.onImage(bytes);
    } else if (file.error != null) {
      widget.onError(file.error!);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!desktopPanelsEnabled) return widget.child;
    _tickerActive = TickerMode.valuesOf(context).enabled;
    return DesktopDropTarget(
      acceptFiles: true,
      acceptText: true,
      onHoverChanged: (hovering) {
        if (mounted) {
          setState(() => _hovering = hovering && widget.enabled && _onScreen());
        }
      },
      onDrop: (event) => unawaited(_onDrop(event)),
      child: Stack(
        children: [
          widget.child,
          // Accent ring and hint while an image is dragged over the avatar.
          if (_hovering)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  key: const ValueKey('desktop-avatar-drop-ring'),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.12),
                    borderRadius: widget.borderRadius,
                    border: Border.all(color: AppColors.accent, width: 2),
                  ),
                  child: Center(
                    child: Text(
                      context.l10n.dropToUseAsAvatar,
                      style: AppText.caption.copyWith(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
