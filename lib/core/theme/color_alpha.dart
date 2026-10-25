import 'package:flutter/material.dart';

/// Alpha helper that works across the Flutter versions this project supports.
///
/// `Color.withOpacity` was deprecated in Flutter 3.27 in favour of
/// `withValues`, but `withValues` does not exist on the older SDKs still
/// allowed by `pubspec.yaml` (`flutter: ">=3.22.0"`). Using either one directly
/// makes the code base either deprecated on new SDKs or uncompilable on old
/// ones — and `flutter analyze` is a CI gate, so a deprecation warning is a
/// build failure.
///
/// `withAlpha` is available on every version in that range and is not
/// deprecated anywhere, so the call sites depend on it through this extension
/// instead.
extension ColorAlpha on Color {
  /// Returns this colour with [opacity] (0.0–1.0) as its alpha channel.
  ///
  /// Same result as the old `withOpacity`: the alpha channel is replaced, not
  /// multiplied.
  Color withAlphaFactor(double opacity) =>
      withAlpha((opacity.clamp(0.0, 1.0) * 255).round());
}
