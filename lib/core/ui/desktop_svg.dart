import 'package:flutter/foundation.dart';
// flutter_svg is built on vector_graphics and passes this choice straight
// to it, but does not re-export the type itself.
// ignore: depend_on_referenced_packages
import 'package:vector_graphics/vector_graphics_compat.dart'
    show RenderingStrategy;

/// How tinted SVG icons are drawn.
///
/// Windows: as a small picture made once per icon, size and screen scale and
/// then reused. A tinted icon drawn the normal way (as vector shapes with a
/// colour filter) makes the graphics card draw it off-screen first and blend
/// it back on every frame, for every icon on screen: the sidebar, the
/// caption buttons, the top bar, the banner buttons and the star on each
/// poster card. On built-in laptop graphics those off-screen steps add up to
/// several milliseconds per frame. The ready-made picture is one plain draw
/// with the colour applied while drawing, and it is made at the exact
/// screen size, so it looks the same.
///
/// Every other platform keeps the normal vector drawing.
RenderingStrategy get desktopSvgStrategy =>
    defaultTargetPlatform == TargetPlatform.windows
    ? RenderingStrategy.raster
    : RenderingStrategy.picture;
