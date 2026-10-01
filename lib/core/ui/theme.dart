import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:juno/core/ui/tokens.dart';
import 'package:juno/core/ui/type.dart';

/// Builds Material [ThemeData] from Juno tokens so stock widgets (dialogs,
/// date pickers, snackbars, text fields) already look like they belong.
abstract final class JTheme {
  static ThemeData light() => _build(JColors.light);
  static ThemeData dark() => _build(JColors.dark);

  static ThemeData _build(JColors c) {
    final scheme = ColorScheme(
      brightness: c.brightness,
      primary: c.brand,
      onPrimary: c.onAccent,
      secondary: c.household,
      onSecondary: c.onAccent,
      error: c.expense,
      onError: c.onAccent,
      surface: c.bg,
      onSurface: c.ink,
      onSurfaceVariant: c.inkMuted,
      surfaceContainerLowest: c.bg,
      surfaceContainerLow: c.surface,
      surfaceContainer: c.surface,
      surfaceContainerHigh: c.raised,
      surfaceContainerHighest: c.raised,
      outline: c.hairlineStrong,
      outlineVariant: c.hairline,
    );

    TextStyle ink(TextStyle s, [Color? color]) => s.copyWith(color: color ?? c.ink);

    final hairlineBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(JRadius.chip),
      borderSide: BorderSide(color: c.hairline),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: c.brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: c.bg,
      canvasColor: c.bg,
      fontFamily: JType.sans,
      extensions: [c],
      splashFactory: InkSparkle.splashFactory,
      splashColor: c.ink.withValues(alpha: 0.05),
      highlightColor: Colors.transparent,
      hoverColor: c.ink.withValues(alpha: 0.03),
      textTheme: TextTheme(
        displayLarge: ink(JType.heroMetric),
        headlineMedium: ink(JType.screenTitle),
        titleLarge: ink(JType.panelTitle),
        titleMedium: ink(JType.rowTitle),
        titleSmall: ink(JType.rowTitle),
        bodyLarge: ink(JType.body.copyWith(fontSize: 15)),
        bodyMedium: ink(JType.body),
        bodySmall: ink(JType.body.copyWith(fontSize: 12), c.inkMuted),
        labelLarge: ink(JType.button),
        labelMedium: ink(JType.panelLabel, c.inkMuted),
        labelSmall: ink(JType.microLabel, c.inkFaint),
      ),
      iconTheme: IconThemeData(color: c.inkMuted, size: 20),
      dividerTheme: DividerThemeData(color: c.hairline, space: 1, thickness: 1),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.bg,
        modalBackgroundColor: c.bg,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: c.hairlineStrong,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(JRadius.sheet)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.bg,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(JRadius.card),
          side: BorderSide(color: c.hairline),
        ),
        titleTextStyle: ink(JType.panelTitle),
        contentTextStyle: ink(JType.body, c.inkMuted),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: c.isDark ? c.raised : c.navBar,
        contentTextStyle: JType.bodyStrong.copyWith(
          color: c.isDark ? c.ink : const Color(0xFFFBF5EA),
        ),
        actionTextColor: c.isDark ? c.brand : const Color(0xFFE79A9B),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(JRadius.chip),
        ),
        elevation: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surface,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: hairlineBorder,
        enabledBorder: hairlineBorder,
        focusedBorder: hairlineBorder.copyWith(
          borderSide: BorderSide(color: c.ink.withValues(alpha: 0.5)),
        ),
        errorBorder: hairlineBorder.copyWith(
          borderSide: BorderSide(color: c.expense),
        ),
        hintStyle: JType.body.copyWith(fontSize: 15, color: c.inkFaint),
        labelStyle: JType.panelLabel.copyWith(color: c.inkMuted),
        floatingLabelStyle: JType.panelLabel.copyWith(color: c.inkMuted),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: c.brand,
        selectionColor: c.brand.withValues(alpha: 0.3),
        selectionHandleColor: c.brand,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: c.raised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(JRadius.chip),
          side: BorderSide(color: c.hairline),
        ),
        textStyle: ink(JType.body.copyWith(fontSize: 14)),
      ),
      datePickerTheme: DatePickerThemeData(
        backgroundColor: c.bg,
        surfaceTintColor: Colors.transparent,
        headerBackgroundColor: c.surface,
        headerForegroundColor: c.ink,
        dayStyle: JType.chipLabel,
        yearStyle: JType.chipLabel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(JRadius.card),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.onAccent : c.inkFaint,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.income : c.surface,
        ),
        trackOutlineColor: WidgetStatePropertyAll(c.hairline),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: c.brand),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: c.isDark ? c.raised : c.navBar,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: JType.chipLabel.copyWith(
          color: c.isDark ? c.ink : const Color(0xFFFBF5EA),
        ),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }

  static SystemUiOverlayStyle overlay(JColors c) => SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarBrightness: c.brightness,
    statusBarIconBrightness: c.isDark ? Brightness.light : Brightness.dark,
  );
}
