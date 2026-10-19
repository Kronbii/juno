import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/ui/ui.dart';

void main() {
  var taps = 0;
  Widget app() => MaterialApp(
    theme: JTheme.dark(),
    builder: (context, child) => JCursor(child: child!),
    home: Scaffold(
      body: Column(
        children: [
          const SizedBox(height: 200),
          Center(
            child: TextButton(onPressed: () => taps++, child: const Text('Press me')),
          ),
          const SizedBox(height: 100),
          const SizedBox(width: 240, child: TextField()),
        ],
      ),
    ),
  );

  MouseCursor? active() => RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);
  JCursorState state(WidgetTester t) => t.state<JCursorState>(find.byType(JCursor));

  testWidgets(
    'desktop: brackets replace the pointer, lock onto buttons, give way to text',
    (tester) async {
      taps = 0;
      await tester.pumpWidget(app());
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(20, 20));
      await mouse.moveTo(const Offset(30, 30));
      await tester.pump(const Duration(milliseconds: 100));
      expect(active(), SystemMouseCursors.none);
      expect(state(tester).showing, isTrue);
      expect(state(tester).lockedRect, isNull);

      final button = tester.getRect(find.byType(TextButton));
      await mouse.moveTo(button.center);
      await tester.pump(const Duration(milliseconds: 500));
      expect(active(), SystemMouseCursors.none, reason: 'the button would show a hand');
      final locked = state(tester).lockedRect!;
      expect(locked.contains(button.topLeft) && locked.contains(button.bottomRight), isTrue);

      await mouse.down(button.center);
      await mouse.up();
      await tester.pump();
      expect(taps, 1, reason: 'the overlay never swallows a click');

      await mouse.moveTo(tester.getCenter(find.byType(TextField)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(active(), SystemMouseCursors.text);
      expect(state(tester).showing, isFalse);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('touch platforms keep their own pointer: no overlay at all', (tester) async {
    taps = 0;
    await tester.pumpWidget(app());
    expect(find.byType(JCursor), findsOneWidget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(find.byType(TextButton)));
    await tester.pump();
    expect(active(), SystemMouseCursors.click);
    await tester.tap(find.byType(TextButton));
    expect(taps, 1);
  });
}
