// Renders the app icon with the bundled fonts:
//   flutter test test/icon_test.dart --run-skipped
//   dart run flutter_launcher_icons
@Tags(['shots'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _font(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    l.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
  }
  await l.load();
}

class _Icon extends StatelessWidget {
  const _Icon();

  @override
  Widget build(BuildContext context) => Container(
    width: 1024,
    height: 1024,
    // Warm near-black with a faint burgundy glow from the lower left —
    // Tayseer's hero light, kept to a whisper so it reads at 60px.
    decoration: const BoxDecoration(
      gradient: RadialGradient(
        center: Alignment(-0.7, 0.9),
        radius: 1.3,
        colors: [Color(0xFF3D1A1B), Color(0xFF0E0B0B)],
      ),
    ),
    child: Stack(
      children: [
        // Bikey's accent tick, scaled up.
        Positioned(
          left: 508,
          top: 284,
          child: Container(
            width: 132,
            height: 14,
            decoration: BoxDecoration(color: const Color(0xFFC9686A), borderRadius: BorderRadius.circular(7)),
          ),
        ),
        const Positioned(
          left: 333,
          top: 230,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: 'J',
                  style: TextStyle(
                    fontFamily: 'Manrope',
                    fontWeight: FontWeight.w800,
                    fontSize: 640,
                    height: 1,
                    letterSpacing: -30,
                    color: Color(0xFFFBF5EA),
                  ),
                ),
                TextSpan(
                  text: '.',
                  style: TextStyle(
                    fontFamily: 'InstrumentSerif',
                    fontStyle: FontStyle.italic,
                    fontSize: 760,
                    height: 1,
                    color: Color(0xFFC9686A),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

void main() {
  testWidgets('app icon', (tester) async {
    await tester.runAsync(() async {
      final fonts = Directory('assets/fonts').listSync().map((f) => f.path).toList();
      await _font('Manrope', fonts.where((f) => f.contains('Manrope')).toList());
      await _font('InstrumentSerif', fonts.where((f) => f.contains('InstrumentSerif')).toList());
    });
    tester.view.physicalSize = const Size(1024, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(key: key, child: const _Icon()),
      ),
    );
    await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('assets/icon').createSync(recursive: true);
      File('assets/icon/icon.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  });
}
