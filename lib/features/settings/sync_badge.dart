import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:juno/core/sync/sync_engine.dart';
import 'package:juno/core/ui/ui.dart';

/// A dot + caps label for the sync state. Shape and text carry the state;
/// colour only reinforces it.
class SyncBadge extends ConsumerWidget {
  const SyncBadge({this.compact = false, super.key});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    final s = ref.watch(syncEngineProvider);
    final (label, color) = switch (s.phase) {
      SyncPhase.disabled => ('Local only', c.inkFaint),
      SyncPhase.signedOut => ('Sign in to sync', c.warn),
      SyncPhase.idle => ('Synced', c.income),
      SyncPhase.syncing => ('Syncing', c.warn),
      SyncPhase.error => ('Sync error', c.expense),
    };
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        JDot(color, size: 7),
        const SizedBox(width: 8),
        Text(label.toUpperCase(), style: JType.microLabel.copyWith(color: c.inkMuted)),
      ],
    );
    if (compact) return row;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => context.go('/settings/sync'),
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4), child: row),
    );
  }
}
