import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/sync/sync_engine.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/settings/sync_badge.dart';

class SyncScreen extends ConsumerStatefulWidget {
  const SyncScreen({super.key});

  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _auth({required bool signUp}) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final engine = ref.read(syncEngineProvider.notifier);
    final email = _email.text.trim();
    final msg = signUp ? await engine.signUp(email, _password.text) : await engine.signIn(email, _password.text);
    if (mounted) {
      setState(() {
        _busy = false;
        _message = msg;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final s = ref.watch(syncEngineProvider);

    final Widget body = switch (s.phase) {
      SyncPhase.disabled => JCard(
        accent: JAccent.warn,
        title: 'Running local-only',
        child: Text(
          'This build has no Supabase project configured. Everything stays on this device. '
          'To sync, create a Supabase project, run supabase/migrations/0001_init.sql, and launch with '
          '--dart-define-from-file=supabase.json (see README).',
          style: JType.body.copyWith(color: c.inkMuted, fontSize: 13.5),
        ),
      ),
      SyncPhase.signedOut => JCard(
        title: 'Sign in to sync',
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              JField(
                label: 'Email',
                child: TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                ),
              ),
              JField(
                label: 'Password',
                child: TextField(
                  controller: _password,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  onSubmitted: (_) => _auth(signUp: false),
                ),
              ),
              if (_message != null) ...[
                Text(_message!, style: JType.body.copyWith(color: c.warn)),
                const SizedBox(height: JSpace.md),
              ],
              Row(
                children: [
                  Expanded(
                    child: JButton(
                      label: _busy ? 'Working…' : 'Sign in',
                      expand: true,
                      onPressed: _busy ? null : () => _auth(signUp: false),
                    ),
                  ),
                  const SizedBox(width: JSpace.sm),
                  JButton(
                    label: 'Create account',
                    kind: JButtonKind.secondary,
                    onPressed: _busy ? null : () => _auth(signUp: true),
                  ),
                ],
              ),
              const SizedBox(height: JSpace.md),
              Text(
                'Entries you made before signing in are uploaded on first sync.',
                style: JType.body.copyWith(color: c.inkFaint, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
      _ => JCard(
        title: 'Signed in',
        trailing: const SyncBadge(compact: true),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(s.email ?? '', style: JType.rowTitle.copyWith(color: c.ink)),
            const SizedBox(height: 4),
            Text(
              s.phase == SyncPhase.error
                  ? 'Last sync failed: ${s.message}'
                  : s.lastSynced == null
                  ? 'Not synced yet this session.'
                  : 'Last synced ${TimeOfDay.fromDateTime(s.lastSynced!).format(context)}.',
              style: JType.body.copyWith(color: s.phase == SyncPhase.error ? c.expense : c.inkMuted),
            ),
            const SizedBox(height: JSpace.lg),
            Row(
              children: [
                JButton(
                  label: 'Sync now',
                  icon: Icons.sync_rounded,
                  dense: true,
                  onPressed: s.phase == SyncPhase.syncing
                      ? null
                      : () => ref.read(syncEngineProvider.notifier).syncNow(),
                ),
                const SizedBox(width: JSpace.sm),
                JButton(
                  label: 'Sign out',
                  kind: JButtonKind.secondary,
                  dense: true,
                  onPressed: () => ref.read(syncEngineProvider.notifier).signOut(),
                ),
              ],
            ),
          ],
        ),
      ),
    };

    return JScreen(
      eyebrow: 'Settings · Sync',
      title: 'One ledger, *everywhere*',
      subtitle:
          'Juno works offline first. Sync keeps your desktop and iPhone in step through your own Supabase project.',
      actions: [
        JIconButton(icon: Icons.arrow_back_rounded, tooltip: 'Back', onPressed: () => Navigator.of(context).maybePop()),
      ],
      slivers: [SliverToBoxAdapter(child: body)],
    );
  }
}
