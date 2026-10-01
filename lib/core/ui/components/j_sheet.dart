import 'package:flutter/material.dart';
import 'package:juno/core/ui/components/j_screen.dart';
import 'package:juno/core/ui/tokens.dart';
import 'package:juno/core/ui/type.dart';

/// Shows [child] as a bottom sheet on phones and a dialog on desktop, with a
/// serif-accented title. Returns whatever the content pops with.
Future<T?> showJSheet<T>(BuildContext context, {required String title, required Widget child}) {
  final wide = MediaQuery.sizeOf(context).width >= JSize.wideBreakpoint;
  final body = _SheetBody(title: title, child: child);
  if (wide) {
    return showDialog<T>(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480, maxHeight: 760), child: body),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    useRootNavigator: true,
    builder: (_) => body,
  );
}

class _SheetBody extends StatelessWidget {
  const _SheetBody({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= JSize.wideBreakpoint;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(JSpace.page + 2, wide ? 24 : 0, JSpace.page + 2, JSpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              JTitle(title, style: JType.panelTitle.copyWith(fontSize: 22)),
              const SizedBox(height: JSpace.lg),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// A caps label above a form control.
class JField extends StatelessWidget {
  const JField({required this.label, required this.child, super.key});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: JSpace.lg),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label.toUpperCase(), style: JType.microLabel.copyWith(color: context.jc.inkFaint)),
        const SizedBox(height: JSpace.sm),
        child,
      ],
    ),
  );
}
