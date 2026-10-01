import 'package:flutter/material.dart';
import 'package:juno/core/ui/tokens.dart';
import 'package:juno/core/ui/type.dart';

/// A title with one emphasised word set in Instrument Serif italic.
///
/// Wrap the word in asterisks: `'Where it *went*'`. Lazpress's rule: one
/// italic word per heading, never more.
class JTitle extends StatelessWidget {
  const JTitle(this.text, {this.style, this.accentColor, this.maxLines, super.key});

  final String text;
  final TextStyle? style;

  /// Colour of the italic word; defaults to the brand accent.
  final Color? accentColor;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final base = (style ?? JType.screenTitle).copyWith(color: style?.color ?? c.ink);
    final italic = JType.accentItalic.copyWith(
      fontSize: (base.fontSize ?? 28) * 1.12,
      color: accentColor ?? c.brand,
      height: base.height,
    );
    final parts = text.split('*');
    return Text.rich(
      TextSpan(
        children: [
          for (var i = 0; i < parts.length; i++) TextSpan(text: parts[i], style: i.isOdd ? italic : base),
        ],
      ),
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
    );
  }
}

/// Mono caps eyebrow, e.g. `01 — OVERVIEW`.
class JEyebrow extends StatelessWidget {
  const JEyebrow(this.text, {this.color, super.key});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: JType.panelLabel.copyWith(
      color: color ?? context.jc.inkFaint,
      letterSpacing: 1.8,
    ),
  );
}

/// Room the shell's floating nav occupies at the bottom of the screen. The
/// shell publishes it so screens can pad their last row clear of the bar.
class JNavInset extends InheritedWidget {
  const JNavInset({required this.height, required super.child, super.key});

  final double height;

  static double of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<JNavInset>()?.height ?? 0;

  @override
  bool updateShouldNotify(JNavInset oldWidget) => oldWidget.height != height;
}

/// The page scaffold: eyebrow, serif-accented title, optional actions, then
/// slivers. Centred to a readable width on desktop.
class JScreen extends StatelessWidget {
  const JScreen({
    required this.title,
    required this.slivers,
    this.eyebrow,
    this.subtitle,
    this.actions = const [],
    this.header,
    this.controller,
    super.key,
  });

  final String title;
  final String? eyebrow;
  final String? subtitle;
  final List<Widget> actions;

  /// Widget pinned under the title (e.g. a scope chip bar).
  final Widget? header;
  final List<Widget> slivers;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final wide = MediaQuery.sizeOf(context).width >= JSize.wideBreakpoint;
    final hPad = wide ? JSpace.pageWide : JSpace.page;
    final bottom = JNavInset.of(context) + JSpace.xxl;

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: JSize.contentMax + JSpace.pageWide * 2),
            child: CustomScrollView(
              controller: controller,
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(hPad, wide ? 36 : 14, hPad, 0),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (eyebrow != null) ...[
                                    JEyebrow(eyebrow!),
                                    const SizedBox(height: 10),
                                  ],
                                  JTitle(
                                    title,
                                    style: wide ? JType.screenTitle.copyWith(fontSize: 36, letterSpacing: -1.4) : null,
                                  ),
                                  if (subtitle != null) ...[
                                    const SizedBox(height: 6),
                                    Text(subtitle!, style: JType.body.copyWith(color: c.inkMuted)),
                                  ],
                                ],
                              ),
                            ),
                            for (final a in actions) ...[const SizedBox(width: JSpace.sm), a],
                          ],
                        ),
                        if (header != null) ...[const SizedBox(height: JSpace.lg), header!],
                        const SizedBox(height: JSpace.lg),
                      ],
                    ),
                  ),
                ),
                for (final s in slivers)
                  SliverPadding(
                    padding: EdgeInsets.symmetric(horizontal: hPad),
                    sliver: s,
                  ),
                SliverToBoxAdapter(child: SizedBox(height: bottom)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An empty state: a viewfinder-cornered frame (Bikey's placeholder) holding
/// an icon, a line of copy and an optional action.
class JEmpty extends StatelessWidget {
  const JEmpty({
    required this.icon,
    required this.title,
    this.message,
    this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    return CustomPaint(
      painter: _CornerMarks(c.hairlineStrong),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: c.inkFaint),
            const SizedBox(height: JSpace.md),
            Text(
              title,
              textAlign: TextAlign.center,
              style: JType.rowTitle.copyWith(color: c.ink),
            ),
            if (message != null) ...[
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: JType.body.copyWith(color: c.inkMuted),
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: JSpace.lg), action!],
          ],
        ),
      ),
    );
  }
}

class _CornerMarks extends CustomPainter {
  _CornerMarks(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    const inset = 1.0;
    final len = (size.shortestSide * 0.12).clamp(8.0, 18.0);
    const l = inset;
    const t = inset;
    final r = size.width - inset;
    final b = size.height - inset;
    canvas
      ..drawLine(const Offset(l, t), Offset(l + len, t), p)
      ..drawLine(const Offset(l, t), Offset(l, t + len), p)
      ..drawLine(Offset(r, t), Offset(r - len, t), p)
      ..drawLine(Offset(r, t), Offset(r, t + len), p)
      ..drawLine(Offset(l, b), Offset(l + len, b), p)
      ..drawLine(Offset(l, b), Offset(l, b - len), p)
      ..drawLine(Offset(r, b), Offset(r - len, b), p)
      ..drawLine(Offset(r, b), Offset(r, b - len), p);
  }

  @override
  bool shouldRepaint(_CornerMarks old) => old.color != color;
}

/// Fades and lifts its child into place once, staggered by [index].
class JReveal extends StatefulWidget {
  const JReveal({required this.child, this.index = 0, super.key});

  final Widget child;
  final int index;

  @override
  State<JReveal> createState() => _JRevealState();
}

class _JRevealState extends State<JReveal> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: JMotion.reveal);
  late final Animation<double> _t = CurvedAnimation(parent: _c, curve: JMotion.ease);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (JMotion.reduced(context)) {
      _c.value = 1;
    } else if (!_c.isAnimating && _c.value == 0) {
      Future.delayed(Duration(milliseconds: 40 * widget.index.clamp(0, 8)), () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _t,
    builder: (_, child) => Opacity(
      opacity: _t.value,
      child: Transform.translate(offset: Offset(0, 16 * (1 - _t.value)), child: child),
    ),
    child: widget.child,
  );
}
