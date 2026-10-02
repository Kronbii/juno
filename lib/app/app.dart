import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/app/router.dart';
import 'package:juno/core/db/backups.dart';
import 'package:juno/core/db/housekeeping.dart';
import 'package:juno/core/deeplink/deep_link_handler.dart';
import 'package:juno/core/ios/intent_inbox.dart';
import 'package:juno/core/lock/app_lock.dart';
import 'package:juno/core/notify/reminder_runner.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/sync/sync_engine.dart';
import 'package:juno/core/toast.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/onboarding/onboarding_screen.dart';
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeOnboard());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Back after a while: the date may have moved on — if it did, the
      // new-day listener below does the foreground work.
      final before = ref.read(todayProvider);
      ref.read(todayProvider.notifier).refresh();
      if (ref.read(todayProvider) == before) _onForeground();
    }
  }

  /// First launch on a fresh device: a short welcome. Skipped when there is
  /// already data (a reinstall that synced, or the sample data).
  Future<void> _maybeOnboard() async {
    final prefs = ref.read(prefsProvider);
    if (prefs.getBool(OnboardingScreen.doneKey) ?? false) return;
    final any = await ref.read(databaseProvider).customSelect('SELECT COUNT(*) AS n FROM transactions').getSingle();
    if (any.read<int>('n') > 0) {
      await prefs.setBool(OnboardingScreen.doneKey, true);
      return;
    }
    final nav = rootNavigatorKey.currentState;
    if (nav == null) return;
    await nav.push(MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => const OnboardingScreen()));
  }

  bool _foregroundRunning = false;
  bool _foregroundAgain = false;

  /// Launch, resume and a new day: one run at a time — a resume that also
  /// changes the date asks twice, and two inbox drains would collide. A
  /// request while running queues one more run.
  Future<void> _onForeground() async {
    if (_foregroundRunning) {
      _foregroundAgain = true;
      return;
    }
    _foregroundRunning = true;
    try {
      do {
        _foregroundAgain = false;
        await _foregroundOnce();
      } while (_foregroundAgain && mounted);
    } finally {
      _foregroundRunning = false;
    }
  }

  /// Catch up with other devices, then post due recurring entries — from the
  /// latest copy of each rule, so a phone opened after weeks doesn't post
  /// bills deleted or changed elsewhere — then share them.
  Future<void> _foregroundOnce() async {
    final db = ref.read(databaseProvider);
    // Entries logged from Siri/Shortcuts/widgets while Juno was closed.
    final imported = await IntentInbox.drain(db);
    if (imported > 0) showToast('Added $imported entr${imported == 1 ? 'y' : 'ies'} logged from Shortcuts');
    await IntentInbox.publishCatalog(db);
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      try {
        await Backups(db).snapshotIfDue();
      } on Object {
        // A failed backup must never block opening the app.
      }
    }
    try {
      await Housekeeping.runIfDue(db, ref.read(prefsProvider));
    } on Object {
      // Tidying is never worth blocking the app for.
    }
    final sync = ref.read(syncEngineProvider.notifier);
    await sync.syncNow();
    if (await materializeRecurring(db) > 0) await sync.syncNow();
    await ref.read(reminderRunnerProvider.notifier).run();
  }

  @override
  Widget build(BuildContext context) {
    // A new day with the app open (midnight on a desktop left running):
    // post the day's bills and re-plan reminders, as on launch.
    ref.listen(todayProvider, (before, now) {
      if (before != null && before != now) _onForeground();
    });
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
