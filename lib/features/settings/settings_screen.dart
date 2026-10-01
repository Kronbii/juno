import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:juno/core/db/demo.dart';
import 'package:juno/core/lock/app_lock.dart';
import 'package:juno/core/notify/reminder_runner.dart';
import 'package:juno/core/notify/reminders.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/sync/sync_engine.dart';
import 'package:juno/core/toast.dart';
import 'package:juno/core/ui/ui.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    final mode = ref.watch(themeModeProvider);
    final sync = ref.watch(syncEngineProvider);
    final accounts = ref.watch(accountsProvider).value?.length ?? 0;
    final categories = ref.watch(categoriesProvider).value?.length ?? 0;

    final syncValue = switch (sync.phase) {
      SyncPhase.disabled => 'Local only',
      SyncPhase.signedOut => 'Sign in',
      SyncPhase.idle => 'On',
      SyncPhase.syncing => 'Syncing…',
      SyncPhase.error => 'Error',
    };

    return JScreen(
      eyebrow: '05 — Settings',
      title: 'Make it *yours*',
      slivers: [
        SliverList.list(
          children: [
            const JSectionLabel('Money', top: 0),
            JGroup(
              children: [
                JSettingRow(
                  icon: Icons.account_balance_wallet_outlined,
                  title: 'Accounts',
                  subtitle: 'Checking, cash, cards and their opening balances',
                  value: '$accounts',
                  onTap: () => context.go('/settings/accounts'),
                ),
                JSettingRow(
                  icon: Icons.category_outlined,
                  title: 'Categories',
                  subtitle: 'Names, icons, colours, default scope',
                  value: '$categories',
                  onTap: () => context.go('/settings/categories'),
                ),
                JSettingRow(
                  icon: Icons.currency_exchange_rounded,
                  title: 'Currencies',
                  subtitle: 'LBP and other rates against USD',
                  value: '${ref.watch(ratesProvider).length}',
                  onTap: () => context.go('/settings/currencies'),
                ),
                JSettingRow(
                  icon: Icons.upload_file_rounded,
                  title: 'Import & export',
                  subtitle: 'Bring in a bank CSV, or export everything',
                  onTap: () => context.go('/settings/import'),
                ),
              ],
            ),
            const JSectionLabel('iPhone'),
            JGroup(
              children: [
                JSettingRow(
                  icon: Icons.touch_app_outlined,
                  title: 'Back Tap quick add',
                  subtitle: 'Double-tap the back of your phone to log an expense',
                  onTap: () => context.go('/settings/back-tap'),
                ),
              ],
            ),
            const JSectionLabel('Privacy & alerts'),
            JGroup(
              children: [
                if (AppLock.available)
                  JSettingRow(
                    icon: Icons.face_retouching_natural_outlined,
                    title: 'Face ID lock',
                    subtitle: 'Ask on open and after a minute away',
                    trailing: Switch(
                      value: ref.watch(lockEnabledProvider),
                      onChanged: (v) async {
                        final ok = await ref.read(lockEnabledProvider.notifier).set(v);
                        if (!ok) showToast('Face ID didn’t confirm — lock left off');
                      },
                    ),
                  ),
                const _NotifyRow(
                  prefKey: Reminders.billsKey,
                  icon: Icons.event_outlined,
                  title: 'Bill reminders',
                  subtitle: 'Recurring payments, on the day they’re due',
                ),
                const _NotifyRow(
                  prefKey: Reminders.budgetsKey,
                  icon: Icons.notifications_active_outlined,
                  title: 'Budget alerts',
                  subtitle: 'At 80% of a limit, and when you go over',
                ),
              ],
            ),
            const JSectionLabel('Sync'),
            JGroup(
              children: [
                JSettingRow(
                  icon: Icons.cloud_sync_outlined,
                  title: 'Cloud sync',
                  subtitle: sync.email ?? 'Keep desktop and iPhone in step',
                  value: syncValue,
                  onTap: () => context.go('/settings/sync'),
                ),
              ],
            ),
            const JSectionLabel('Appearance'),
            JGroup(
              children: [
                Padding(
                  padding: const EdgeInsets.all(JSpace.card),
                  child: JSegmentBar<ThemeMode>(
                    segments: const {ThemeMode.system: 'System', ThemeMode.light: 'Light', ThemeMode.dark: 'Dark'},
                    selected: mode,
                    onChanged: (m) => ref.read(themeModeProvider.notifier).set(m),
                  ),
                ),
              ],
            ),
            const JSectionLabel('Data'),
            JGroup(
              children: [
                if (kDebugMode)
                  JSettingRow(
                    icon: Icons.science_outlined,
                    title: 'Load sample data',
                    subtitle: 'Debug builds only — four months of demo entries',
                    onTap: () async {
                      await seedDemo(ref.read(databaseProvider));
                      showToast('Sample data loaded');
                    },
                  ),
                JSettingRow(
                  icon: Icons.restart_alt_rounded,
                  title: 'Reset local data',
                  subtitle: 'Wipes this device. Synced data stays in the cloud.',
                  destructive: true,
                  onTap: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Reset this device?'),
                        content: const Text(
                          'Every entry, budget and goal on this device will be deleted. '
                          'This cannot be undone unless you sync.',
                        ),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: Text('Reset', style: TextStyle(color: c.expense)),
                          ),
                        ],
                      ),
                    );
                    if (ok ?? false) {
                      await ref.read(ledgerProvider).wipe();
                      showToast('Local data cleared');
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: JSpace.xxl),
            Center(
              child: Column(
                children: [
                  const JWordmark(size: 40),
                  const SizedBox(height: 8),
                  Text(
                    'PERSONAL & HOUSEHOLD · USD',
                    style: JType.microLabel.copyWith(color: c.inkFaint, letterSpacing: 1.8),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _NotifyRow extends ConsumerStatefulWidget {
  const _NotifyRow({required this.prefKey, required this.icon, required this.title, required this.subtitle});

  final String prefKey;
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  ConsumerState<_NotifyRow> createState() => _NotifyRowState();
}

class _NotifyRowState extends ConsumerState<_NotifyRow> {
  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(prefsProvider);
    final on = prefs.getBool(widget.prefKey) ?? true;
    return JSettingRow(
      icon: widget.icon,
      title: widget.title,
      subtitle: widget.subtitle,
      trailing: Switch(
        value: on,
        onChanged: (v) async {
          if (v && !await ref.read(remindersProvider).requestPermission()) {
            showToast('Allow notifications for Juno in iOS Settings');
            return;
          }
          await prefs.setBool(widget.prefKey, v);
          setState(() {});
          await ref.read(reminderRunnerProvider.notifier).run();
        },
      ),
    );
  }
}
