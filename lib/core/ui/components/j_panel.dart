import 'package:flutter/material.dart';
import 'package:juno/core/ui/tokens.dart';
import 'package:juno/core/ui/type.dart';

/// The short accent rule that sits above a caps label — Bikey's signature in
/// place of a coloured card.
class JTick extends StatelessWidget {
  const JTick(this.color, {super.key});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 22,
    height: 2,
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(1)),
  );
}

/// A hairline-bounded panel for grouped content.
///
/// Separated from the page by a 1px rule rather than a change of fill, so a
/// screen of several panels reads as one divided surface.
class JCard extends StatelessWidget {
  const JCard({
    required this.child,
    this.title,
    this.accent,
    this.trailing,
    this.onTap,
    this.padding = const EdgeInsets.all(JSpace.card),
    this.alert = false,
    super.key,
  });

  final Widget child;

  /// Optional caps header.
  final String? title;

  /// When set, a [JTick] in this accent sits above the title.
  final JAccent? accent;

  /// Right-hand side of the header.
  final Widget? trailing;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  /// A wash of the accent and a coloured border — for something that is
  /// genuinely wrong (over budget).
  final bool alert;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final accentColor = accent?.of(c);
    final isAlert = alert && accentColor != null;

    return Material(
      color: isAlert ? c.tint(accentColor) : c.surface,
      borderRadius: BorderRadius.circular(JRadius.card),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(JRadius.card),
            border: Border.all(
              color: isAlert ? accentColor.withValues(alpha: 0.45) : c.hairline,
            ),
          ),
          child: Padding(
            padding: padding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (accentColor != null) ...[
                  JTick(accentColor),
                  const SizedBox(height: JSpace.md),
                ],
                if (title != null) ...[
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title!.toUpperCase(),
                          style: JType.panelLabel.copyWith(color: c.inkMuted),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      ?trailing,
                      if (trailing == null && onTap != null)
                        Icon(Icons.arrow_outward_rounded, size: 14, color: c.inkFaint),
                    ],
                  ),
                  const SizedBox(height: JSpace.md),
                ],
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A labelled figure: tick, caps label, mono value + unit, caption.
class JMetricTile extends StatelessWidget {
  const JMetricTile({
    required this.accent,
    required this.label,
    required this.value,
    this.unit,
    this.caption,
    this.captionColor,
    this.compact = false,
    this.onTap,
    this.alert = false,
    super.key,
  });

  final JAccent accent;
  final String label;

  /// Either a pre-formatted string or a widget (e.g. a count-up figure).
  final Object value;
  final String? unit;
  final String? caption;
  final Color? captionColor;
  final bool compact;
  final VoidCallback? onTap;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final style = (compact ? JType.panelMetric : JType.heroMetric).copyWith(color: c.ink);
    final v = value;

    return Semantics(
      label: '$label ${v is String ? v : ''} ${unit ?? ''}'.trim(),
      button: onTap != null,
      child: JCard(
        accent: accent,
        alert: alert,
        onTap: onTap,
        padding: EdgeInsets.all(compact ? JSpace.card : JSpace.tile),
        title: label,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: v is Widget
                        ? DefaultTextStyle.merge(style: style, child: v)
                        : Text(v.toString(), maxLines: 1, style: style),
                  ),
                ),
                if (unit != null) ...[
                  const SizedBox(width: 6),
                  Text(unit!.toUpperCase(), style: JType.unit.copyWith(color: c.inkMuted)),
                ],
              ],
            ),
            if (caption != null) ...[
              SizedBox(height: compact ? JSpace.xs : JSpace.sm),
              Text(
                caption!,
                style: JType.body.copyWith(color: captionColor ?? c.inkMuted),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A figure above a caps caption: `$412.20` / `AVG / DAY`.
class JMicroStat extends StatelessWidget {
  const JMicroStat({
    required this.value,
    required this.label,
    this.valueColor,
    super.key,
  });

  final String value;
  final String label;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value, maxLines: 1, style: JType.cardMetric.copyWith(color: valueColor ?? c.ink)),
        ),
        const SizedBox(height: 6),
        Text(
          label.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: JType.microLabel.copyWith(color: c.inkFaint),
        ),
      ],
    );
  }
}

/// A flat 3px progress bar on a hairline track. Turns warn at 80%, expense
/// when over.
class JProgress extends StatelessWidget {
  const JProgress({required this.value, this.color, this.height = 3, super.key});

  /// 0..1+ ; values above 1 render full in the over colour.
  final double value;
  final Color? color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final v = value.isNaN ? 0.0 : value;
    final fill =
        color ??
        (v >= 1
            ? c.expense
            : v >= 0.8
            ? c.warn
            : c.income);
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, box) => Stack(
          children: [
            Container(color: c.hairline),
            TweenAnimationBuilder<double>(
              tween: Tween(end: v.clamp(0, 1)),
              duration: JMotion.reduced(context) ? Duration.zero : JMotion.reveal,
              curve: JMotion.ease,
              builder: (_, t, _) => Container(width: box.maxWidth * t, color: fill),
            ),
          ],
        ),
      ),
    );
  }
}

/// Caps divider above a list.
class JSectionLabel extends StatelessWidget {
  const JSectionLabel(this.text, {this.trailing, this.top = JSpace.xl, super.key});

  final String text;
  final Widget? trailing;
  final double top;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: top, bottom: JSpace.md),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text.toUpperCase(),
            style: JType.microLabel.copyWith(color: context.jc.inkFaint),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

/// A small read-only outlined capsule of data.
class JPill extends StatelessWidget {
  const JPill(this.text, {this.color, this.filled = false, super.key});

  final String text;
  final Color? color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final ink = color ?? c.inkMuted;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: filled ? c.tint(ink) : null,
        borderRadius: BorderRadius.circular(JRadius.pill),
        border: Border.all(color: color == null ? c.hairline : ink.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        child: Text(text.toUpperCase(), style: JType.microLabel.copyWith(color: ink, fontSize: 9)),
      ),
    );
  }
}

/// A coloured dot, used to key categories and scopes.
class JDot extends StatelessWidget {
  const JDot(this.color, {this.size = 8, super.key});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}
