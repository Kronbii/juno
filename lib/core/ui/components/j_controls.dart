import 'package:flutter/material.dart';
import 'package:juno/core/ui/tokens.dart';
import 'package:juno/core/ui/type.dart';

enum JButtonKind {
  /// Filled with the accent. One per screen.
  primary,

  /// Hairline outline, plain ink. Everything else.
  secondary,

  /// No border, accent ink. Inline actions.
  ghost,
}

/// The app's button — a pill, per Lazpress's shape rule: anything you press
/// is round, content stays square-ish.
class JButton extends StatelessWidget {
  const JButton({
    required this.label,
    required this.onPressed,
    this.kind = JButtonKind.primary,
    this.accent = JAccent.brand,
    this.icon,
    this.expand = false,
    this.dense = false,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final JButtonKind kind;
  final JAccent accent;
  final IconData? icon;
  final bool expand;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final a = accent.of(c);
    final enabled = onPressed != null;
    final (bg, fg, side) = switch (kind) {
      JButtonKind.primary => (a, c.onAccent, BorderSide.none),
      JButtonKind.secondary => (Colors.transparent, c.ink, BorderSide(color: c.hairlineStrong)),
      JButtonKind.ghost => (Colors.transparent, a, BorderSide.none),
    };

    return AnimatedOpacity(
      duration: JMotion.fast,
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: bg,
        clipBehavior: Clip.antiAlias,
        shape: StadiumBorder(side: side),
        child: InkWell(
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: dense ? 40 : 52),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: dense ? JSpace.lg : JSpace.xl),
              child: Row(
                mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 18, color: fg),
                    const SizedBox(width: JSpace.sm),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: JType.button.copyWith(color: fg),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A round hairline icon button (44pt).
class JIconButton extends StatelessWidget {
  const JIconButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.color,
    this.size = 44,
    super.key,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final button = Material(
      color: Colors.transparent,
      shape: CircleBorder(side: BorderSide(color: c.hairline)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox.square(
          dimension: size,
          child: Icon(icon, size: 18, color: color ?? c.inkMuted),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }
}

/// A selectable chip. Selected = accent border over a thin tint.
class JChip extends StatelessWidget {
  const JChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.accent = JAccent.brand,
    this.leading,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final JAccent accent;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final a = accent.of(c);
    return Semantics(
      selected: selected,
      button: true,
      child: AnimatedContainer(
        duration: JMotion.fast,
        curve: JMotion.ease,
        decoration: ShapeDecoration(
          color: selected ? c.tint(a) : Colors.transparent,
          shape: StadiumBorder(side: BorderSide(color: selected ? a : c.hairline)),
        ),
        child: Material(
          type: MaterialType.transparency,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 38),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (leading != null) ...[leading!, const SizedBox(width: 8)],
                    Text(
                      label,
                      style: JType.chipLabel.copyWith(
                        fontSize: 12.5,
                        color: selected ? a : c.inkMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A horizontally scrolling single-select row of chips.
class JChipBar extends StatelessWidget {
  const JChipBar({
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
    this.accents,
    this.padding = EdgeInsets.zero,
    super.key,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// Per-chip accents; defaults to brand.
  final List<JAccent>? accents;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 38,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: padding,
      itemCount: labels.length,
      separatorBuilder: (_, _) => const SizedBox(width: JSpace.sm),
      itemBuilder: (context, i) => JChip(
        label: labels[i],
        selected: i == selectedIndex,
        accent: accents?[i] ?? JAccent.brand,
        onTap: () => onSelected(i),
      ),
    ),
  );
}

/// A segmented control: hairline track, the selected segment gets a tint and
/// an accent border that slides between positions.
class JSegmentBar<T> extends StatelessWidget {
  const JSegmentBar({
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.accentOf,
    super.key,
  });

  final Map<T, String> segments;
  final T selected;
  final ValueChanged<T> onChanged;
  final JAccent Function(T)? accentOf;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final keys = segments.keys.toList();
    final index = keys.indexOf(selected).clamp(0, keys.length - 1);
    final a = (accentOf?.call(selected) ?? JAccent.brand).of(c);

    return Container(
      height: 46,
      padding: const EdgeInsets.all(3),
      decoration: ShapeDecoration(
        shape: StadiumBorder(side: BorderSide(color: c.hairline)),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth / keys.length;
          return Stack(
            children: [
              AnimatedPositioned(
                duration: JMotion.reduced(context) ? Duration.zero : JMotion.medium,
                curve: JMotion.ease,
                left: w * index,
                top: 0,
                bottom: 0,
                width: w,
                child: AnimatedContainer(
                  duration: JMotion.fast,
                  decoration: ShapeDecoration(
                    color: c.tint(a),
                    shape: StadiumBorder(side: BorderSide(color: a.withValues(alpha: 0.6))),
                  ),
                ),
              ),
              Row(
                children: [
                  for (final k in keys)
                    Expanded(
                      child: Semantics(
                        selected: k == selected,
                        button: true,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onChanged(k),
                          child: Center(
                            child: AnimatedDefaultTextStyle(
                              duration: JMotion.fast,
                              style: JType.chipLabel.copyWith(
                                fontSize: 12.5,
                                color: k == selected ? a : c.inkMuted,
                              ),
                              child: Text(segments[k]!.toUpperCase()),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A hairline list row: leading, title/subtitle, trailing.
class JListRow extends StatelessWidget {
  const JListRow({
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.boxed = true,
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Boxed rows are standalone panels; unboxed rows sit inside a [JCard] or
  /// a list separated by hairlines.
  final bool boxed;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final content = Padding(
      padding: EdgeInsets.symmetric(horizontal: boxed ? JSpace.card : 0, vertical: 12),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: JSpace.md)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: JType.rowTitle.copyWith(color: c.ink),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: JType.body.copyWith(fontSize: 12, color: c.inkFaint),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: JSpace.md), trailing!],
        ],
      ),
    );

    if (!boxed) {
      return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(8), child: content);
    }
    return Material(
      color: c.surface,
      borderRadius: BorderRadius.circular(JRadius.row),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(JRadius.row),
            border: Border.all(color: c.hairline),
          ),
          child: content,
        ),
      ),
    );
  }
}

/// A settings row: icon, title, subtitle, value chip or chevron.
class JSettingRow extends StatelessWidget {
  const JSettingRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.value,
    this.trailing,
    this.onTap,
    this.destructive = false,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final ink = destructive ? c.expense : c.ink;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 60),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: JSpace.card, vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: 19, color: destructive ? c.expense : c.inkMuted),
              const SizedBox(width: JSpace.md + 2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: JType.rowTitle.copyWith(color: ink)),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(subtitle!, style: JType.body.copyWith(fontSize: 12, color: c.inkFaint)),
                    ],
                  ],
                ),
              ),
              if (trailing != null)
                trailing!
              else if (value != null)
                JPillValue(value!)
              else if (onTap != null)
                Icon(Icons.chevron_right_rounded, size: 20, color: c.inkFaint),
            ],
          ),
        ),
      ),
    );
  }
}

class JPillValue extends StatelessWidget {
  const JPillValue(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: StadiumBorder(side: BorderSide(color: c.hairline)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Text(text, style: JType.chipLabel.copyWith(color: c.inkMuted)),
      ),
    );
  }
}

/// Groups setting rows in a hairline panel with dividers between rows.
class JGroup extends StatelessWidget {
  const JGroup({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    return Material(
      color: c.surface,
      borderRadius: BorderRadius.circular(JRadius.card),
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(JRadius.card),
          border: Border.all(color: c.hairline),
        ),
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Divider(indent: JSpace.card + 33, color: c.hairline),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// The search input.
class JSearchField extends StatelessWidget {
  const JSearchField({required this.hint, this.controller, this.onChanged, super.key});

  final String hint;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      style: JType.bodyStrong.copyWith(fontSize: 15, color: c.ink),
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Icon(Icons.search_rounded, size: 19, color: c.inkFaint),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(JRadius.pill),
          borderSide: BorderSide(color: c.hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(JRadius.pill),
          borderSide: BorderSide(color: c.hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(JRadius.pill),
          borderSide: BorderSide(color: c.hairlineStrong),
        ),
      ),
    );
  }
}
