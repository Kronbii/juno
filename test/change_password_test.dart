import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/app/router.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/settings/sync_screen.dart';

void main() {
  final saved = <String>[];
  String? serverError;

  Future<void> open(WidgetTester tester) async {
    saved.clear();
    serverError = null;
    await tester.pumpWidget(
      MaterialApp(
        theme: JTheme.light(),
        scaffoldMessengerKey: scaffoldMessengerKey,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showJSheet<void>(
                  context,
                  title: 'New *password*',
                  child: ChangePasswordSheet(
                    onSave: (p) async {
                      saved.add(p);
                      return serverError;
                    },
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester, String a, String b) async {
    await tester.enterText(find.byType(TextField).at(0), a);
    await tester.enterText(find.byType(TextField).at(1), b);
    await tester.tap(find.text('Save password'));
    await tester.pumpAndSettle();
  }

  testWidgets('too short or mismatched never reaches the server', (tester) async {
    await open(tester);
    await submit(tester, 'short', 'short');
    expect(find.textContaining('at least 8'), findsOneWidget);
    await submit(tester, 'longenough1', 'longenough2');
    expect(find.textContaining('don’t match'), findsOneWidget);
    expect(saved, isEmpty);
    expect(find.byType(ChangePasswordSheet), findsOneWidget);
  });

  testWidgets('a server refusal is shown and the sheet stays open to retry', (tester) async {
    await open(tester);
    serverError = 'New password should be different from the old password.';
    await submit(tester, 'longenough1', 'longenough1');
    expect(find.text(serverError!), findsOneWidget);
    expect(find.byType(ChangePasswordSheet), findsOneWidget);
    expect(find.text('Save password'), findsOneWidget, reason: 'the button comes back after a failure');
  });

  testWidgets('a matching password is saved, the sheet closes and says so', (tester) async {
    await open(tester);
    await submit(tester, 'longenough1', 'longenough1');
    expect(saved, ['longenough1']);
    expect(find.byType(ChangePasswordSheet), findsNothing);
    expect(find.textContaining('Password changed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
