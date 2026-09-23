import 'package:catppuccin_flutter/catppuccin_flutter.dart';
import 'package:flutter/material.dart';

/// Catppuccin Macchiato theme for the whole app.
///
/// Palette reference: https://github.com/catppuccin/vscode
class AppTheme {
  const AppTheme._();

  static final Flavor _flavor = catppuccin.macchiato;

  static Flavor get flavor => _flavor;

  /// Semantic finance colors, themed to the Catppuccin palette.
  static Color get income => _flavor.green;
  static Color get expense => _flavor.red;

  static ThemeData get theme {
    final f = _flavor;
    final accentContainer =
        Color.alphaBlend(f.mauve.withValues(alpha: 0.35), f.surface0);
    final scheme = ColorScheme.dark(
      surface: f.base,
      onSurface: f.text,
      surfaceContainerHighest: f.surface0,
      surfaceContainerHigh: f.mantle,
      primary: f.mauve,
      onPrimary: f.crust,
      primaryContainer: accentContainer,
      onPrimaryContainer: f.text,
      secondary: f.blue,
      onSecondary: f.crust,
      secondaryContainer: accentContainer,
      onSecondaryContainer: f.text,
      tertiary: f.teal,
      onTertiary: f.crust,
      error: f.red,
      onError: f.crust,
      outline: f.overlay0,
      outlineVariant: f.surface1,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: f.base,
      appBarTheme: AppBarTheme(
        backgroundColor: f.mantle,
        foregroundColor: f.text,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: f.surface0,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: f.mantle,
        indicatorColor: f.surface1,
        labelTextStyle: WidgetStateProperty.all(
          TextStyle(color: f.subtext0, fontSize: 12),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected) ? f.mauve : f.subtext0,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: f.surface0,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: f.surface1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: f.surface1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: f.mauve),
        ),
      ),
      dividerColor: f.surface1,
    );
  }
}
