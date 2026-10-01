import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/add/entry_sheet.dart';
import 'package:juno/features/settings/sync_badge.dart';

const navItems = [
  JNavItem(label: 'Home', icon: Icons.space_dashboard_outlined, accent: JAccent.brand),
  JNavItem(label: 'Activity', icon: Icons.receipt_long_outlined, accent: JAccent.household),
  JNavItem(label: 'Insights', icon: Icons.insights_outlined, accent: JAccent.warn),
  JNavItem(label: 'Plan', icon: Icons.flag_outlined, accent: JAccent.income),
  JNavItem(label: 'Settings', icon: Icons.tune_rounded, accent: JAccent.brand),
];

/// Adaptive shell: floating pill nav on phones, hairline side rail on
/// desktop. `N` opens a new entry anywhere; Ctrl+1…5 jump between tabs.
class AppShell extends StatelessWidget {
  const AppShell({required this.shell, super.key});

  final StatefulNavigationShell shell;

  void _go(int i) => shell.goBranch(i, initialLocation: i == shell.currentIndex);

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final wide = MediaQuery.sizeOf(context).width >= JSize.wideBreakpoint;
    void add() => showEntrySheet(context);

    final body = Shortcuts(
      shortcuts: {
        const SingleActivator(LogicalKeyboardKey.keyN): const _NewEntryIntent(),
        for (var i = 0; i < navItems.length; i++)
          SingleActivator(LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i), control: true): _TabIntent(i),
      },
      child: Actions(
        actions: {
          _NewEntryIntent: _NewEntryAction(add),
          _TabIntent: CallbackAction<_TabIntent>(onInvoke: (t) => _go(t.index)),
        },
        child: Focus(autofocus: true, child: shell),
      ),
    );

    if (wide) {
      return Scaffold(
        backgroundColor: c.bg,
        body: Row(
          children: [
            JSideRail(
              items: navItems,
              currentIndex: shell.currentIndex,
              onSelected: _go,
              onAdd: add,
              footer: const SyncBadge(),
            ),
            Expanded(child: body),
          ],
        ),
      );
    }

    final reserved = JBottomNav.reservedHeight(context);
    return Scaffold(
      backgroundColor: c.bg,
      extendBody: true,
      body: Stack(
        children: [
          Positioned.fill(
            child: JNavInset(height: reserved, child: body),
          ),
          // A fade behind the floating bar so content passing under it
          // dissolves instead of colliding with the pill.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: reserved + 24,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [c.bg, c.bg.withValues(alpha: 0.92), c.bg.withValues(alpha: 0)],
                    stops: const [0, 0.55, 1],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: JBottomNav(
              items: navItems,
              currentIndex: shell.currentIndex,
              onSelected: (i) {
                HapticFeedback.selectionClick();
                _go(i);
              },
              onAdd: () {
                HapticFeedback.lightImpact();
                add();
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _NewEntryIntent extends Intent {
  const _NewEntryIntent();
}

class _TabIntent extends Intent {
  const _TabIntent(this.index);

  final int index;
}

/// `N` for a new entry — disabled while a text field has focus. A disabled
/// action makes Shortcuts return "ignored", so the key reaches the field and
/// types an n (a callback that merely does nothing would still swallow it).
class _NewEntryAction extends Action<_NewEntryIntent> {
  _NewEntryAction(this.onNew);

  final VoidCallback onNew;

  @override
  bool isEnabled(_NewEntryIntent intent) {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return true;
    final typing = ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null;
    return !typing;
  }

  @override
  void invoke(_NewEntryIntent intent) => onNew();
}
