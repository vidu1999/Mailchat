import 'package:flutter/material.dart';

/// MailChat design system.
///
/// Defines light/dark color tokens, typography and component themes derived
/// from Material 3 ColorScheme. All screens must use these tokens instead of
/// ad-hoc colors so light/dark/system themes stay consistent.
class AppTheme {
  AppTheme._();

  static const Color _brand = Color(0xFF6366F1); // indigo primary
  static const Color _brandDark = Color(0xFF818CF8);

  static const Color _surfaceDark = Color(0xFF0F172A);
  static const Color _surfaceDarkElevated = Color(0xFF1E293B);

  static const Color _errorColor = Color(0xFFEF4444);

  // ------------------------------------------------------------------
  // Light theme
  // ------------------------------------------------------------------
  static ThemeData get lightTheme {
    final colorScheme = ColorScheme.light(
      brightness: Brightness.light,
      primary: _brand,
      onPrimary: Colors.white,
      primaryContainer: const Color(0xFFE0E7FF),
      onPrimaryContainer: const Color(0xFF1E1B4B),
      secondary: const Color(0xFF64748B),
      onSecondary: Colors.white,
      surface: Colors.white,
      onSurface: const Color(0xFF0F172A),
      surfaceVariant: const Color(0xFFF1F5F9),
      onSurfaceVariant: const Color(0xFF334155),
      background: const Color(0xFFFAFAFA),
      onBackground: const Color(0xFF0F172A),
      error: _errorColor,
      onError: Colors.white,
      surfaceTint: _brand,
    );
    return _buildTheme(colorScheme);
  }

  // ------------------------------------------------------------------
  // Dark theme
  // ------------------------------------------------------------------
  static ThemeData get darkTheme {
    final colorScheme = ColorScheme.dark(
      brightness: Brightness.dark,
      primary: _brandDark,
      onPrimary: Colors.white,
      primaryContainer: const Color(0xFF1E1B4B),
      onPrimaryContainer: const Color(0xFFE0E7FF),
      secondary: const Color(0xFF94A3B8),
      onSecondary: Colors.white,
      surface: _surfaceDark,
      onSurface: Colors.white,
      surfaceVariant: _surfaceDarkElevated,
      onSurfaceVariant: const Color(0xFFCBD5E1),
      background: _surfaceDark,
      onBackground: Colors.white,
      error: const Color(0xFFF87171),
      onError: Colors.black,
      surfaceTint: _brandDark,
    );
    return _buildTheme(colorScheme);
  }

  static ThemeData _buildTheme(ColorScheme colorScheme) {
    return ThemeData(
            useMaterial3: true,
            colorScheme: colorScheme,
            brightness: colorScheme.brightness,
          )
      .copyWith(
        scaffoldBackgroundColor: colorScheme.background,
        cardColor: colorScheme.surface,
        dividerColor: colorScheme.outlineVariant.withOpacity(0.5),

        // Bottom navigation (used by MainChatList bottom bar)
        bottomNavigationBarTheme: BottomNavigationBarThemeData(
          backgroundColor: colorScheme.surface,
          selectedItemColor: colorScheme.primary,
          unselectedItemColor: colorScheme.onSurfaceVariant,
          type: BottomNavigationBarType.fixed,
          elevation: 8,
        ),

        // Inputs
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: colorScheme.surfaceVariant,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 14,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: colorScheme.outlineVariant.withOpacity(0.6),
              width: 1,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: colorScheme.primary, width: 2),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: colorScheme.error, width: 1),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: colorScheme.error, width: 2),
          ),
        ),

        // Buttons
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            foregroundColor: Colors.white,
            backgroundColor: colorScheme.primary,
            minimumSize: const Size(double.infinity, 52),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            elevation: 0,
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),

        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: colorScheme.primary,
            minimumSize: const Size(double.infinity, 52),
            padding: const EdgeInsets.symmetric(vertical: 14),
            side: BorderSide(color: colorScheme.primary, width: 1.5),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),

        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: colorScheme.primary,
            textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
        ),

        // Text
        textTheme: const TextTheme(
          displayLarge: TextStyle(fontSize: 32, fontWeight: FontWeight.w700, letterSpacing: -0.5),
          headlineMedium: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
          titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          bodyLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w400, height: 1.5),
          bodyMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w400, height: 1.45),
          labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          bodySmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
        ),

        // List tiles
        listTileTheme: ListTileThemeData(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          dense: true,
        ),
      );
  }
}
