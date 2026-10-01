import 'package:flutter/material.dart';
import 'package:juno/app/router.dart';

/// App-level snackbar that works from anywhere (deep links, sheets that have
/// already closed).
void showToast(String message, {VoidCallback? onUndo, Duration duration = const Duration(seconds: 4)}) {
  final m = scaffoldMessengerKey.currentState;
  if (m == null) return;
  m
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration,
        action: onUndo == null ? null : SnackBarAction(label: 'UNDO', onPressed: onUndo),
      ),
    );
}
