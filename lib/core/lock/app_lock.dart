import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:local_auth/local_auth.dart';

/// Face ID / Touch ID lock. iOS (and macOS) only — Linux has no system
/// biometric prompt, so the setting is hidden there.
abstract final class AppLock {
  static const key = 'lock.enabled';

  /// How long Juno may sit in the background before it locks again.
  static const grace = Duration(seconds: 60);

  static bool get available =>
      !kIsWeb && !Platform.environment.containsKey('FLUTTER_TEST') && (Platform.isIOS || Platform.isMacOS);

  static final _auth = LocalAuthentication();

  static Future<bool> deviceCanLock() async {
    if (!available) return false;
    try {
      return await _auth.isDeviceSupported();
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> authenticate() async {
    try {
      return await _auth.authenticate(localizedReason: 'Unlock Juno to see your finances');
    } on PlatformException {
      return false;
    } on LocalAuthException {
      return false;
    }
  }
}

class LockEnabled extends Notifier<bool> {
  @override
  bool build() => AppLock.available && (ref.watch(prefsProvider).getBool(AppLock.key) ?? false);

  /// Turning the lock on requires a successful unlock first, so nobody
  /// locks themselves out with a device that can't authenticate.
  Future<bool> set(bool on) async {
    if (on && !await AppLock.authenticate()) return false;
    state = on;
    await ref.read(prefsProvider).setBool(AppLock.key, on);
    return true;
  }
}

final lockEnabledProvider = NotifierProvider<LockEnabled, bool>(LockEnabled.new);

/// Covers the app with a lock screen on launch and after [AppLock.grace] in
/// the background. Also blurs content in the app switcher.
class LockGate extends ConsumerStatefulWidget {
  const LockGate({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<LockGate> createState() => _LockGateState();
}

class _LockGateState extends ConsumerState<LockGate> with WidgetsBindingObserver {
  late bool _locked = ref.read(lockEnabledProvider);
  bool _obscured = false;
  bool _prompting = false;
  DateTime? _leftAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_locked) WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!ref.read(lockEnabledProvider)) return;
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        // The Face ID prompt itself makes the app inactive; don't react to it.
        if (!_prompting) setState(() => _obscured = true);
      case AppLifecycleState.paused:
        _leftAt ??= clock.now();
      case AppLifecycleState.resumed:
        final away = _leftAt == null ? Duration.zero : clock.now().difference(_leftAt!);
        _leftAt = null;
        setState(() {
          _obscured = false;
          if (away > AppLock.grace) _locked = true;
        });
        if (_locked) _unlock();
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _unlock() async {
    if (_prompting) return;
    _prompting = true;
    final ok = await AppLock.authenticate();
    _prompting = false;
    if (ok && mounted) setState(() => _locked = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final cover = _locked || _obscured;
    return Stack(
      children: [
        // Keep the app mounted (and its state) underneath the cover.
        ExcludeSemantics(excluding: cover, child: widget.child),
        if (cover)
          Positioned.fill(
            child: ColoredBox(
              color: c.bg,
              child: SafeArea(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const JWordmark(size: 48),
                      const SizedBox(height: JSpace.xl),
                      if (_locked)
                        JButton(label: 'Unlock', icon: Icons.lock_open_rounded, onPressed: _unlock)
                      else
                        Icon(Icons.lock_outline_rounded, color: c.inkFaint),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
