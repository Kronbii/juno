import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:juno/core/ui/tokens.dart';

/// The lock-on cursor from Rami's site: four corner brackets around a dot
/// that sits exactly on the pointer. Over anything clickable the brackets
/// spring out to frame it in sage; over text the system I-beam takes over.
/// Moved fast, the dot splits into green and magenta along the motion.
/// Desktop mouse only — touch and trackpad-less platforms keep their own.
class JCursor extends StatefulWidget {
  const JCursor({required this.child, super.key});

  final Widget child;

  static bool get supported =>
      !kIsWeb &&
      switch (defaultTargetPlatform) {
        TargetPlatform.linux || TargetPlatform.macOS || TargetPlatform.windows => true,
        _ => false,
      };

  @override
  State<JCursor> createState() => JCursorState();
}

class JCursorState extends State<JCursor> with SingleTickerProviderStateMixin {
  static const _rest = 22.0;
  static const _pad = 7.0;

  final _region = GlobalKey();
  late final Ticker _ticker;

  Offset _pointer = Offset.zero;
  Offset _velocity = Offset.zero;
  Rect _box = Rect.zero;
  double _lock = 0;
  RenderBox? _target;
  bool _visible = false;
  bool _text = false;
  bool _pressed = false;
  Duration? _last;
  Duration? _lastMove;

  /// The frame the brackets are springing to, null when not locked on.
  @visibleForTesting
  Rect? get lockedRect => _targetRect();

  @visibleForTesting
  bool get showing => _visible && !_text;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  Rect? _targetRect() {
    final t = _target;
    if (t == null || !t.attached || !t.hasSize) return null;
    final r = MatrixUtils.transformRect(t.getTransformTo(null), Offset.zero & t.size);
    final view = MediaQuery.sizeOf(context);
    return Rect.fromLTRB(
      math.max(4, r.left - _pad),
      math.max(4, r.top - _pad),
      math.min(view.width - 4, r.right + _pad),
      math.min(view.height - 4, r.bottom + _pad),
    );
  }

  /// What is under the pointer: something to lock onto, text, or neither.
  void _probe() {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, _pointer, View.of(context).viewId);
    final ours = _region.currentContext?.findRenderObject();
    final view = MediaQuery.sizeOf(context);
    RenderBox? target;
    var text = false;
    for (final entry in result.path) {
      final t = entry.target;
      if (identical(t, ours) || t is! MouseTrackerAnnotation) continue;
      final cursor = (t as MouseTrackerAnnotation).cursor;
      if (cursor == MouseCursor.defer) continue;
      if (cursor == SystemMouseCursors.click && t is RenderBox) {
        // A whole panel that happens to be tappable is not a target to frame.
        final s = t.size;
        if (s.width < view.width * 0.7 || s.height < view.height * 0.5) target = t;
      } else if (cursor == SystemMouseCursors.text) {
        text = true;
      }
      break;
    }
    if (target != _target || text != _text) {
      setState(() {
        _target = target;
        _text = text;
      });
    }
  }

  void _wake() {
    if (!_ticker.isActive) _ticker.start();
  }

  void _onPointer(PointerEvent e) {
    if (e.kind != PointerDeviceKind.mouse) {
      if (_visible) setState(() => _visible = false);
      return;
    }
    if (e is PointerDownEvent) _pressed = true;
    if (e is PointerUpEvent || e is PointerCancelEvent) _pressed = false;
    if (e is PointerHoverEvent || e is PointerMoveEvent) {
      final last = _lastMove;
      if (last != null && _visible) {
        final dt = math.max(0.004, (e.timeStamp - last).inMicroseconds / 1e6);
        final v = (e.position - _pointer) / dt;
        _velocity += (v - _velocity) * 0.35;
      }
      _lastMove = e.timeStamp;
      _pointer = e.position;
      if (!_visible) {
        _box = Rect.fromCenter(center: _pointer, width: _rest, height: _rest);
        setState(() => _visible = true);
      }
      _probe();
    }
    _wake();
  }

  void _onSignal(PointerSignalEvent e) {
    // A scroll moves things under a still pointer.
    if (_visible) SchedulerBinding.instance.addPostFrameCallback((_) => mounted ? _probe() : null);
  }

  void _tick(Duration now) {
    final dt = _last == null ? 1 / 60 : math.min(0.05, (now - _last!).inMicroseconds / 1e6);
    _last = now;
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final locked = _targetRect();
    if (_target != null && locked == null) _target = null;
    final inset = _pressed && locked != null ? 3.0 : 0.0;
    final size = _pressed ? _rest - 6 : _rest;
    final goal = locked?.deflate(inset) ?? Rect.fromCenter(center: _pointer, width: size, height: size);
    final k = reduced ? 1.0 : 1 - math.exp(-dt * (locked != null ? 20 : 34));
    _box = Rect.lerp(_box, goal, k)!;
    _lock += ((locked != null ? 1.0 : 0.0) - _lock) * (reduced ? 1.0 : 1 - math.exp(-dt * 16));
    _velocity *= math.exp(-dt * 10);
    final settled =
        (goal.topLeft - _box.topLeft).distance + (goal.bottomRight - _box.bottomRight).distance < 0.2 &&
        _velocity.distance < 8 &&
        (_lock - (locked != null ? 1 : 0)).abs() < 0.01;
    setState(() {});
    if (settled && locked == null) {
      _ticker.stop();
      _last = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!JCursor.supported) return widget.child;
    final c = context.jc;
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final split = reduced ? Offset.zero : _clampSplit(_velocity * 0.006);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerHover: _onPointer,
      onPointerMove: _onPointer,
      onPointerDown: _onPointer,
      onPointerUp: _onPointer,
      onPointerCancel: _onPointer,
      onPointerSignal: _onSignal,
      child: Stack(
        alignment: Alignment.topLeft,
        textDirection: TextDirection.ltr,
        children: [
          widget.child,
          Positioned.fill(
            child: MouseRegion(
              key: _region,
              opaque: false,
              hitTestBehavior: HitTestBehavior.translucent,
              cursor: _text ? SystemMouseCursors.text : SystemMouseCursors.none,
              onExit: (_) => setState(() => _visible = false),
            ),
          ),
          if (showing)
            Positioned.fill(
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _CursorPainter(
                        box: _box,
                        dot: _pointer,
                        split: split,
                        lock: _lock,
                        rest: c.ink,
                        accent: c.brand,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static Offset _clampSplit(Offset o) => Offset(o.dx.clamp(-9, 9), o.dy.clamp(-9, 9));
}

class _CursorPainter extends CustomPainter {
  _CursorPainter({
    required this.box,
    required this.dot,
    required this.split,
    required this.lock,
    required this.rest,
    required this.accent,
  });

  final Rect box;
  final Offset dot;
  final Offset split;
  final double lock;
  final Color rest;
  final Color accent;

  static const _green = Color(0xFFA6E68F);
  static const _magenta = Color(0xFFE08FD0);

  @override
  void paint(Canvas canvas, Size size) {
    final arm = 7 + 5 * lock;
    final path = Path();
    void corner(Offset at, double dx, double dy) => path
      ..moveTo(at.dx, at.dy + dy * arm)
      ..lineTo(at.dx, at.dy)
      ..lineTo(at.dx + dx * arm, at.dy);
    final r = box.deflate(0.75);
    corner(r.topLeft, 1, 1);
    corner(r.topRight, -1, 1);
    corner(r.bottomLeft, 1, -1);
    corner(r.bottomRight, -1, -1);
    Paint stroke(Color c) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.square
      ..color = c;
    canvas
      ..drawPath(path.shift(const Offset(0.75, 0)), stroke(_green.withValues(alpha: 0.7)))
      ..drawPath(path.shift(const Offset(-0.75, 0)), stroke(_magenta.withValues(alpha: 0.7)))
      ..drawPath(path, stroke(Color.lerp(rest, accent, lock)!));
    final light = Paint()..blendMode = BlendMode.screen;
    canvas
      ..drawCircle(dot + split, 2.5, light..color = _green)
      ..drawCircle(dot - split, 2.5, light..color = _magenta);
  }

  @override
  bool shouldRepaint(_CursorPainter old) =>
      old.box != box ||
      old.dot != dot ||
      old.split != split ||
      old.lock != lock ||
      old.rest != rest ||
      old.accent != accent;
}
