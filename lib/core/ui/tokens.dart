import 'package:flutter/material.dart';

/// Juno palette.
///
/// Built the way Bikey's instrument panel is: grounds stay quiet, structure is
/// carried by 1px hairlines instead of filled blocks, and colour only appears
/// where it means something. The dark ground is Tayseer's warm near-black with
/// cream ink; the light ground is Lazpress's paper white with warm rules.
///
/// Colours live in a [ThemeExtension] (Bikey's were `static const`) so every
/// component reads them through `context.jc` and follows the system theme.
@immutable
class JColors extends ThemeExtension<JColors> {
  const JColors({
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.raised,
    required this.navBar,
    required this.hairline,
    required this.hairlineStrong,
    required this.ink,
    required this.inkMuted,
    required this.inkFaint,
    required this.onAccent,
    required this.brand,
    required this.income,
    required this.expense,
    required this.warn,
    required this.household,
  });

  final Brightness brightness;

  // ---- Grounds ----
  final Color bg;
  final Color surface;
  final Color raised;
  final Color navBar;

  // ---- Structure ----
  final Color hairline;
  final Color hairlineStrong;

  // ---- Ink ----
  final Color ink;
  final Color inkMuted;
  final Color inkFaint;

  /// Ink on a saturated accent fill (the primary button, the + key).
  final Color onAccent;

  // ---- Semantic accents ----
  //
  // Each one means something. Brand doubles as "personal"; teal is
  // "household", so a scope reads at a glance anywhere in the app.

  /// Burgundy. The primary action and the personal scope.
  final Color brand;

  /// Money in.
  final Color income;

  /// Money out, over budget, destructive.
  final Color expense;

  /// Approaching a limit, something falling due.
  final Color warn;

  /// The household scope.
  final Color household;

  bool get isDark => brightness == Brightness.dark;

  /// A thin wash of an accent behind an active element.
  Color tint(Color accent) => accent.withValues(alpha: isDark ? 0.10 : 0.08);

  static const dark = JColors(
    brightness: Brightness.dark,
    bg: Color(0xFF0E0B0B),
    surface: Color(0xFF1A1414),
    raised: Color(0xFF221A1A),
    navBar: Color(0xFF141010),
    hairline: Color(0x1FFBF5EA),
    hairlineStrong: Color(0x3DFBF5EA),
    ink: Color(0xFFFBF5EA),
    inkMuted: Color(0x99FBF5EA),
    inkFaint: Color(0x5CFBF5EA),
    onAccent: Color(0xFF0E0B0B),
    brand: Color(0xFFC9686A),
    income: Color(0xFF3FB950),
    expense: Color(0xFFF4553D),
    warn: Color(0xFFE3B341),
    household: Color(0xFF1FA89E),
  );

  static const light = JColors(
    brightness: Brightness.light,
    bg: Color(0xFFFFFFFF),
    surface: Color(0xFFF6F4F0),
    raised: Color(0xFFEFEBE4),
    navBar: Color(0xFF15171A),
    hairline: Color(0xFFE7E3DC),
    hairlineStrong: Color(0xFFCFC9BF),
    ink: Color(0xFF15171A),
    inkMuted: Color(0xFF3A3D42),
    inkFaint: Color(0xFF7A7D83),
    onAccent: Color(0xFFFFFFFF),
    brand: Color(0xFF8C3839),
    income: Color(0xFF1A7F37),
    expense: Color(0xFFCF2E1F),
    warn: Color(0xFF9A6700),
    household: Color(0xFF008AA0),
  );

  @override
  JColors copyWith() => this;

  @override
  JColors lerp(covariant JColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return JColors(
      brightness: t < 0.5 ? brightness : other.brightness,
      bg: l(bg, other.bg),
      surface: l(surface, other.surface),
      raised: l(raised, other.raised),
      navBar: l(navBar, other.navBar),
      hairline: l(hairline, other.hairline),
      hairlineStrong: l(hairlineStrong, other.hairlineStrong),
      ink: l(ink, other.ink),
      inkMuted: l(inkMuted, other.inkMuted),
      inkFaint: l(inkFaint, other.inkFaint),
      onAccent: l(onAccent, other.onAccent),
      brand: l(brand, other.brand),
      income: l(income, other.income),
      expense: l(expense, other.expense),
      warn: l(warn, other.warn),
      household: l(household, other.household),
    );
  }
}

extension JColorsContext on BuildContext {
  JColors get jc => Theme.of(this).extension<JColors>()!;
}

/// Semantic accent. Components take one of these rather than a raw colour so
/// that meaning survives a palette or theme change.
enum JAccent {
  brand,
  income,
  expense,
  warn,
  household
  ;

  Color of(JColors c) => switch (this) {
    JAccent.brand => c.brand,
    JAccent.income => c.income,
    JAccent.expense => c.expense,
    JAccent.warn => c.warn,
    JAccent.household => c.household,
  };
}

/// Spacing scale. If a gap is not on this scale it is a mistake.
abstract final class JSpace {
  static const page = 18.0;
  static const pageWide = 32.0;
  static const gap = 12.0;
  static const card = 16.0;
  static const tile = 20.0;

  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

/// Corner radii. Lazpress's rule applies: anything pressable is a pill or a
/// soft chip; content panels are calmer.
abstract final class JRadius {
  static const tile = 26.0;
  static const card = 20.0;
  static const row = 18.0;
  static const chip = 14.0;
  static const pill = 999.0;
  static const sheet = 30.0;
}

abstract final class JSize {
  static const minTapTarget = 44.0;

  /// Width at which the shell switches from the floating pill to a side rail.
  static const wideBreakpoint = 840.0;

  /// Readable max width for a single content column on desktop.
  static const contentMax = 1180.0;
}

/// Motion tokens.
abstract final class JMotion {
  /// Lazpress's house curve — a strong ease-out for reveals and lifts.
  static const ease = Cubic(0.2, 0.8, 0.2, 1);

  /// State changes: nav pill, segment, chips (Bikey).
  static const fast = Duration(milliseconds: 180);
  static const medium = Duration(milliseconds: 260);
  static const reveal = Duration(milliseconds: 620);

  static bool reduced(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}
