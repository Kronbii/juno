import 'package:flutter/material.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/ui/tokens.dart';

/// How each scope looks, in one place: chips, dots, bars and cards all read
/// these so a scope is the same colour and icon everywhere.
extension ScopeStyle on Scope {
  JAccent get accent => switch (this) {
    Scope.personal => JAccent.brand,
    Scope.household => JAccent.household,
    Scope.other => JAccent.other,
  };

  Color color(JColors c) => accent.of(c);

  IconData get icon => switch (this) {
    Scope.personal => Icons.person_outline_rounded,
    Scope.household => Icons.home_outlined,
    Scope.other => Icons.category_outlined,
  };
}
