import 'package:flutter/widgets.dart';

/// The Juno type system — three voices, borrowed from Lazpress and given
/// Bikey's discipline.
///
/// * **Manrope** sets language: titles, sentences, buttons. Heavy and tightly
///   tracked at display sizes.
/// * **Instrument Serif italic** is the single emphasised word in a title —
///   "Where it *went*". Never more than one per heading.
/// * **JetBrains Mono** sets data: every amount, date, unit and small caps
///   label. Monospaced digits keep columns of money aligned and stop figures
///   twitching while they count up.
///
/// Styles carry no colour; components apply ink from `context.jc` so the same
/// scale serves both themes.
abstract final class JType {
  static const sans = 'Manrope';
  static const serif = 'InstrumentSerif';
  static const mono = 'JetBrainsMono';

  // ---- Language ----

  static const display = TextStyle(
    fontFamily: sans,
    fontSize: 34,
    fontWeight: FontWeight.w700,
    letterSpacing: -1.2,
    height: 1.05,
  );

  static const screenTitle = TextStyle(
    fontFamily: sans,
    fontSize: 28,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.9,
    height: 1.1,
  );

  static const panelTitle = TextStyle(
    fontFamily: sans,
    fontSize: 19,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
    height: 1.2,
  );

  static const rowTitle = TextStyle(
    fontFamily: sans,
    fontSize: 15,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    height: 1.25,
  );

  static const body = TextStyle(
    fontFamily: sans,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    height: 1.45,
  );

  static const bodyStrong = TextStyle(
    fontFamily: sans,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    height: 1.45,
  );

  static const button = TextStyle(
    fontFamily: sans,
    fontSize: 14,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.1,
    height: 1.2,
  );

  /// The emphasised word inside a title. Sized by the caller to match.
  static const accentItalic = TextStyle(
    fontFamily: serif,
    fontStyle: FontStyle.italic,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.3,
  );

  // ---- Data ----

  static const heroMetric = TextStyle(
    fontFamily: mono,
    fontSize: 48,
    fontWeight: FontWeight.w600,
    letterSpacing: -2.6,
    height: 1,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const panelMetric = TextStyle(
    fontFamily: mono,
    fontSize: 26,
    fontWeight: FontWeight.w600,
    letterSpacing: -1.2,
    height: 1.05,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const cardMetric = TextStyle(
    fontFamily: mono,
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.5,
    height: 1.1,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const rowMetric = TextStyle(
    fontFamily: mono,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
    height: 1.2,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const unit = TextStyle(
    fontFamily: mono,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    height: 1.2,
  );

  /// Every small caps label in the app. Callers upper-case the text.
  static const microLabel = TextStyle(
    fontFamily: mono,
    fontSize: 9.5,
    fontWeight: FontWeight.w500,
    letterSpacing: 1.1,
    height: 1.2,
  );

  static const panelLabel = TextStyle(
    fontFamily: mono,
    fontSize: 10.5,
    fontWeight: FontWeight.w500,
    letterSpacing: 1.2,
    height: 1.2,
  );

  static const chipLabel = TextStyle(
    fontFamily: mono,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 1.2,
  );
}
