import 'package:flutter/material.dart';
import 'package:juno/core/ui/tokens.dart';
import 'package:juno/core/ui/type.dart';

class JNavItem {
  const JNavItem({required this.label, required this.icon, required this.accent});

  final String label;
  final IconData icon;

  /// Each tab owns its accent so the bar reinforces where you are.
  final JAccent accent;
}

/// Bikey's floating tab bar: a pill inset from the edges, page visible behind
/// it. Only the active tab carries its label. A filled "+" at the end opens
/// the add sheet — the most frequent action in a finance app gets the one
/// filled control on the bar.
class JBottomNav extends StatelessWidget {
  const JBottomNav({
    required this.items,
    required this.currentIndex,
    required this.onSelected,
    required this.onAdd,
    super.key,
  });

  final List<JNavItem> items;
  final int currentIndex;
  final ValueChanged<int> onSelected;
  final VoidCallback onAdd;

  static const barHeight = 64.0;
  static const double bottomGap = JSpace.md;

  static double reservedHeight(BuildContext context) =>
      barHeight + bottomGap + MediaQuery.viewPaddingOf(context).bottom;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    // The bar is always the dark navBar ink so it reads as a physical object
    // floating over either theme.
    final onBar = c.isDark ? c.inkFaint : const Color(0x80FBF5EA);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        JSpace.page,
        0,
        JSpace.page,
        bottomGap + MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.navBar,
          borderRadius: BorderRadius.circular(JRadius.tile),
          border: c.isDark ? Border.all(color: c.hairline) : null,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: c.isDark ? 0.45 : 0.18),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: SizedBox(
          height: barHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: JSpace.sm),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < items.length; i++) ...[
                    if (i > 0) const SizedBox(width: JSpace.xs),
                    _PillButton(
                      item: items[i],
                      selected: i == currentIndex,
                      idleColor: onBar,
                      onTap: () => onSelected(i),
                    ),
                  ],
                  const SizedBox(width: JSpace.sm),
                  _AddButton(onTap: onAdd),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.item,
    required this.selected,
    required this.idleColor,
    required this.onTap,
  });

  final JNavItem item;
  final bool selected;
  final Color idleColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Accents on the always-dark bar use the dark palette.
    final a = item.accent.of(JColors.dark);
    final dur = JMotion.reduced(context) ? Duration.zero : const Duration(milliseconds: 220);
    return Semantics(
      selected: selected,
      button: true,
      label: item.label,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: dur,
          curve: Curves.easeOutCubic,
          height: 46,
          padding: EdgeInsets.symmetric(horizontal: selected ? 14 : 12),
          decoration: BoxDecoration(
            color: selected ? a.withValues(alpha: 0.12) : Colors.transparent,
            borderRadius: BorderRadius.circular(JRadius.pill),
            border: Border.all(color: selected ? a.withValues(alpha: 0.5) : Colors.transparent),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(item.icon, size: 22, color: selected ? a : idleColor),
              AnimatedSize(
                duration: dur,
                curve: Curves.easeOutCubic,
                child: selected
                    ? Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(
                          item.label.toUpperCase(),
                          maxLines: 1,
                          softWrap: false,
                          style: JType.microLabel.copyWith(color: a, fontSize: 10),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final a = JColors.dark.brand;
    return Semantics(
      button: true,
      label: 'Add transaction',
      child: Material(
        color: a,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: const SizedBox(
            width: 54,
            height: 46,
            child: Icon(Icons.add_rounded, size: 24, color: Color(0xFF0E0B0B)),
          ),
        ),
      ),
    );
  }
}

/// Desktop navigation: a hairline-bounded rail with the wordmark, a primary
/// "New entry" pill and labelled destinations.
class JSideRail extends StatelessWidget {
  const JSideRail({
    required this.items,
    required this.currentIndex,
    required this.onSelected,
    required this.onAdd,
    this.footer,
    super.key,
  });

  final List<JNavItem> items;
  final int currentIndex;
  final ValueChanged<int> onSelected;
  final VoidCallback onAdd;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    return Container(
      width: 232,
      decoration: BoxDecoration(
        color: c.bg,
        border: Border(right: BorderSide(color: c.hairline)),
      ),
      child: SafeArea(
        right: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const JWordmark(),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: Material(
                  color: c.brand,
                  shape: const StadiumBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: onAdd,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
                      child: Row(
                        children: [
                          Icon(Icons.add_rounded, size: 19, color: c.onAccent),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text('New entry', style: JType.button.copyWith(color: c.onAccent)),
                          ),
                          Text('N', style: JType.chipLabel.copyWith(color: c.onAccent.withValues(alpha: 0.6))),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              for (var i = 0; i < items.length; i++)
                _RailItem(
                  item: items[i],
                  index: i,
                  selected: i == currentIndex,
                  onTap: () => onSelected(i),
                ),
              const Spacer(),
              ?footer,
            ],
          ),
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.item,
    required this.index,
    required this.selected,
    required this.onTap,
  });

  final JNavItem item;
  final int index;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final a = item.accent.of(c);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(JRadius.chip),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: AnimatedContainer(
            duration: JMotion.fast,
            curve: JMotion.ease,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: selected ? c.tint(a) : Colors.transparent,
              borderRadius: BorderRadius.circular(JRadius.chip),
              border: Border.all(color: selected ? a.withValues(alpha: 0.45) : Colors.transparent),
            ),
            child: Row(
              children: [
                Icon(item.icon, size: 19, color: selected ? a : c.inkFaint),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    item.label,
                    style: JType.rowTitle.copyWith(
                      fontSize: 14,
                      color: selected ? c.ink : c.inkMuted,
                    ),
                  ),
                ),
                Text(
                  '0${index + 1}',
                  style: JType.microLabel.copyWith(color: selected ? a : c.inkFaint),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Juno." — Manrope 800 with the full stop in serif italic burgundy, a nod
/// to Lazpress's footer wordmark.
class JWordmark extends StatelessWidget {
  const JWordmark({this.size = 26, super.key});

  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: 'Juno',
            style: TextStyle(
              fontFamily: JType.sans,
              fontWeight: FontWeight.w800,
              fontSize: size,
              letterSpacing: -size * 0.05,
              color: c.ink,
              height: 1,
            ),
          ),
          TextSpan(
            text: '.',
            style: JType.accentItalic.copyWith(fontSize: size * 1.2, color: c.brand, height: 1),
          ),
        ],
      ),
    );
  }
}
