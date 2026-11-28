import 'dart:ui';
import 'package:flutter/material.dart';

/// Clips a modal sheet's translucent blur so underlying content remains visible
/// without painting the backdrop effect outside its rounded upper corners.
class FrostedSheet extends StatelessWidget {
  const FrostedSheet({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
      // Paint the tint on the same Material as ListTile ink, so hover and
      // selection feedback stays visible above the frosted background.
      child: Material(color: const Color(0xAA16161C), child: child),
    ),
  );
}
