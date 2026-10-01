import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/app/router.dart';
import 'package:juno/core/deeplink/deep_link_handler.dart';
import 'package:juno/core/ios/intent_inbox.dart';
import 'package:juno/core/lock/app_lock.dart';
import 'package:juno/core/notify/reminder_runner.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/sync/sync_engine.dart';
import 'package:juno/core/toast.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/plan/recurrence.dart';

class JunoApp extends ConsumerStatefulWidget {
  const JunoApp({super.key});

  @override
  ConsumerState<JunoApp> createState() => _JunoAppState();
}

class _JunoAppState extends ConsumerState<JunoApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _onForeground();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onForeground();
  }

  /// Launch and resume: post due recurring entries, then sync.
  Future<void> _onForeground() async {
    final db = ref.read(databaseProvider);
    // Entries logged from Siri/Shortcuts/widgets while Juno was closed.
    final imported = await IntentInbox.drain(db);
    if (imported > 0) showToast('Added $imported entr${imported == 1 ? 'y' : 'ies'} logged from Shortcuts');
    await IntentInbox.publishCatalog(db);
    await materializeRecurring(db);
    await ref.read(syncEngineProvider.notifier).syncNow();
    await ref.read(reminderRunnerProvider.notifier).run();
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      title: 'Juno',
      debugShowCheckedModeBanner: false,
      theme: JTheme.light(),
      darkTheme: JTheme.dark(),
      themeMode: mode,
      routerConfig: router,
      scaffoldMessengerKey: scaffoldMessengerKey,
      builder: (context, child) {
        final c = context.jc;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: JTheme.overlay(c),
          child: LockGate(child: DeepLinkHandler(child: child!)),
        );
      },
    );
  }
}
