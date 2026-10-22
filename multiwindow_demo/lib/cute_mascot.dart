import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A small self-animating mascot: a mochi cat that bobs, blinks, wiggles its
/// ears and keeps a few hearts and sparkles floating around itself.
///
/// Tapping it (or changing [burst]) plays a short happy pop. Everything is
/// painted on a single 176x176 canvas, so it stays cheap enough to run in every
/// window at once.
class CuteMascot extends StatefulWidget {
  const CuteMascot({
    super.key,
    required this.accent,
    required this.ink,
    this.burst = 0,
    this.size = 176,
    this.onTap,
  });

  /// Colour used for the blush, inner ears and floating hearts.
  final Color accent;

  /// Dark colour used for the face and the soft outlines.
  final Color ink;

  /// Change this to play a happy pop, e.g. pass a tap counter.
  final int burst;

  final double size;
  final VoidCallback? onTap;

  @override
  State<CuteMascot> createState() => _CuteMascotState();
}

class _CuteMascotState extends State<CuteMascot> with TickerProviderStateMixin {
  late final AnimationController _idle = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  )..repeat();

  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didUpdateWidget(CuteMascot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.burst != oldWidget.burst) {
      _pop.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _idle.dispose();
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'A cute cat mascot. Tap it for a happy bounce.',
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: CustomPaint(
            size: Size.square(widget.size),
            painter: _MascotPainter(
              idle: _idle,
              pop: _pop,
              accent: widget.accent,
              ink: widget.ink,
            ),
          ),
        ),
      ),
    );
  }
}

/// One floating heart or sparkle in the mascot's little aura.
class _Floaty {
  const _Floaty({
    required this.x,
    required this.y,
    required this.phase,
    required this.size,
    required this.drift,
    required this.heart,
  });

  final double x;
  final double y;
  final double phase;
  final double size;
  final double drift;
  final bool heart;
}

class _MascotPainter extends CustomPainter {
  _MascotPainter({
    required this.idle,
    required this.pop,
    required this.accent,
    required this.ink,
  }) : super(repaint: Listenable.merge(<Listenable>[idle, pop]));

  final Animation<double> idle;
  final Animation<double> pop;
  final Color accent;
  final Color ink;

  static const Color _gold = Color(0xFFFFC95C);

  static const List<_Floaty> _floaties = <_Floaty>[
    _Floaty(x: 26, y: 98, phase: 0.0, size: 6, drift: 7, heart: true),
    _Floaty(x: 38, y: 62, phase: 0.52, size: 4.5, drift: 9, heart: false),
    _Floaty(x: 150, y: 86, phase: 0.28, size: 5.5, drift: 8, heart: true),
    _Floaty(x: 138, y: 48, phase: 0.74, size: 4, drift: 6, heart: false),
    _Floaty(x: 88, y: 24, phase: 0.4, size: 4, drift: 10, heart: false),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final double t = idle.value;
    final double popT = pop.value;

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(size.shortestSide / 176);
    canvas.translate(-88, -88);

    _paintShadow(canvas, t);
    _paintFloaties(canvas, t);
    _paintMascot(canvas, t, popT);
    _paintBurst(canvas, popT);

    canvas.restore();
  }

  void _paintShadow(Canvas canvas, double t) {
    final double lift = (math.sin(t * math.pi * 2) + 1) / 2;
    canvas.drawOval(
      Rect.fromCenter(
        center: const Offset(88, 151),
        width: 82 - lift * 10,
        height: 13 - lift * 2,
      ),
      Paint()
        ..color = accent.withValues(alpha: 0.18 * (1 - lift * 0.45))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
  }

  void _paintFloaties(Canvas canvas, double t) {
    for (final _Floaty f in _floaties) {
      final double p = (t + f.phase) % 1;
      final double opacity = math.sin(p * math.pi) * 0.8;
      if (opacity < 0.02) continue;
      final Offset center = Offset(
        f.x + math.sin(p * math.pi * 2 + f.phase * math.pi * 2) * f.drift,
        f.y - p * 26,
      );
      final Paint paint = Paint()
        ..color = (f.heart ? accent : _gold).withValues(alpha: opacity);
      if (f.heart) {
        _drawHeart(canvas, center, f.size, paint);
      } else {
        _drawSparkle(canvas, center, f.size, paint);
      }
    }
  }

  void _paintMascot(Canvas canvas, double t, double popT) {
    final double bob = math.sin(t * math.pi * 2) * 3.6;
    final double bounce = popT > 0
        ? math.sin(popT * math.pi * 2) * math.exp(-3.2 * popT) * 0.09
        : 0.0;

    canvas.save();
    // Squash and stretch around the feet so the pop reads as a little hop.
    canvas.translate(88, 148);
    canvas.scale(1 - bounce * 0.5, 1 + bounce);
    canvas.translate(-88, -148);
    canvas.translate(0, bob);

    _paintEar(canvas, t, right: false);
    _paintEar(canvas, t, right: true);
    _paintBody(canvas);
    _paintFace(canvas, t, popT);

    canvas.restore();
  }

  void _paintEar(Canvas canvas, double t, {required bool right}) {
    final double wiggle = math.sin(t * math.pi * 4) * 0.045;
    canvas.save();
    if (right) {
      canvas.translate(176, 0);
      canvas.scale(-1, 1);
    }
    canvas.translate(58, 82);
    canvas.rotate(wiggle);
    canvas.translate(-58, -82);

    final Path ear = Path()
      ..moveTo(46, 84)
      ..quadraticBezierTo(42, 44, 58, 38)
      ..quadraticBezierTo(70, 46, 78, 74)
      ..close();
    canvas.drawPath(ear, Paint()..color = Colors.white);
    canvas.drawPath(
      ear,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = ink.withValues(alpha: 0.14)
        ..strokeJoin = StrokeJoin.round,
    );

    final Path inner = Path()
      ..moveTo(53, 79)
      ..quadraticBezierTo(50, 55, 58, 49)
      ..quadraticBezierTo(66, 56, 70, 75)
      ..close();
    canvas.drawPath(inner, Paint()..color = accent.withValues(alpha: 0.5));

    canvas.restore();
  }

  void _paintBody(Canvas canvas) {
    const Rect rect = Rect.fromLTRB(40, 66, 136, 146);
    final RRect body = RRect.fromRectAndRadius(rect, const Radius.circular(40));
    canvas.drawRRect(
      body,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Colors.white,
            Color.lerp(Colors.white, accent, 0.16)!,
          ],
        ).createShader(rect),
    );
    canvas.drawRRect(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = ink.withValues(alpha: 0.14),
    );

    final Paint pawPaint = Paint()
      ..color = Color.lerp(Colors.white, accent, 0.22)!;
    final Paint toePaint = Paint()
      ..color = ink.withValues(alpha: 0.16)
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    for (final double x in <double>[68, 108]) {
      canvas.drawOval(
        Rect.fromCenter(center: Offset(x, 143), width: 22, height: 9),
        pawPaint,
      );
      canvas.drawLine(Offset(x, 140), Offset(x, 146), toePaint);
    }
  }

  void _paintFace(Canvas canvas, double t, double popT) {
    final bool happy = popT > 0.02 && popT < 0.75;

    // Two quick blinks per 6 second cycle.
    double blink = 0;
    for (final double center in const <double>[0.18, 0.63]) {
      double d = (t - center).abs();
      d = math.min(d, 1 - d);
      const double half = 0.035;
      if (d < half) {
        blink = math.max(blink, math.sin((1 - d / half) * math.pi * 0.5));
      }
    }

    const double eyeY = 106;
    final Paint inkPaint = Paint()..color = ink;
    final Paint stroke = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round;

    for (final double cx in const <double>[66, 110]) {
      if (happy) {
        canvas.drawPath(
          Path()
            ..moveTo(cx - 4.5, eyeY + 2.5)
            ..quadraticBezierTo(cx, eyeY - 3.5, cx + 4.5, eyeY + 2.5),
          stroke,
        );
      } else if (blink > 0.7) {
        canvas.drawLine(Offset(cx - 4, eyeY), Offset(cx + 4, eyeY), stroke);
      } else {
        final double scaleY = 1 - 0.9 * blink;
        canvas.save();
        canvas.translate(cx, eyeY);
        canvas.scale(1, scaleY);
        canvas.drawOval(
          Rect.fromCenter(center: Offset.zero, width: 7, height: 9),
          inkPaint,
        );
        canvas.drawCircle(
          const Offset(-1.4, -2.2),
          1.5,
          Paint()..color = Colors.white.withValues(alpha: 0.9),
        );
        canvas.restore();
      }
    }

    // Blush.
    final Paint blush = Paint()..color = accent.withValues(alpha: 0.5);
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(48, 117), width: 15, height: 8),
      blush,
    );
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(128, 117), width: 15, height: 8),
      blush,
    );

    if (happy) {
      final Rect mouth = Rect.fromCenter(
        center: const Offset(88, 118),
        width: 14,
        height: 11,
      );
      canvas.save();
      canvas.clipPath(Path()..addOval(mouth));
      canvas.drawOval(mouth, inkPaint);
      canvas.drawOval(
        Rect.fromCenter(center: const Offset(88, 123), width: 10, height: 6),
        Paint()..color = accent.withValues(alpha: 0.8),
      );
      canvas.restore();
    } else {
      canvas.drawArc(
        Rect.fromCenter(center: const Offset(88, 114), width: 12, height: 9),
        math.pi * 0.15,
        math.pi * 0.7,
        false,
        Paint()
          ..color = ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
    }

    // Whiskers.
    final Paint whisker = Paint()
      ..color = ink.withValues(alpha: 0.28)
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(44, 110), const Offset(26, 106), whisker);
    canvas.drawLine(const Offset(44, 117), const Offset(26, 119), whisker);
    canvas.drawLine(const Offset(132, 110), const Offset(150, 106), whisker);
    canvas.drawLine(const Offset(132, 117), const Offset(150, 119), whisker);
  }

  void _paintBurst(Canvas canvas, double popT) {
    if (popT <= 0 || popT >= 1) return;
    final double p = Curves.easeOutCubic.transform(popT);
    final double fade = 1 - popT;
    for (int i = 0; i < 3; i++) {
      final double angle = -math.pi / 2 + (i - 1) * 0.55;
      final Offset center = Offset(
        88 + math.cos(angle) * (26 + 46 * p),
        100 + math.sin(angle) * (26 + 46 * p),
      );
      _drawHeart(
        canvas,
        center,
        5.5 * (0.6 + 0.4 * fade),
        Paint()..color = accent.withValues(alpha: 0.9 * fade),
      );
    }
  }

  void _drawHeart(Canvas canvas, Offset c, double r, Paint paint) {
    final Path path = Path()
      ..moveTo(c.dx, c.dy + r * 0.65)
      ..cubicTo(
        c.dx - r * 1.2,
        c.dy - r * 0.1,
        c.dx - r * 0.7,
        c.dy - r,
        c.dx,
        c.dy - r * 0.3,
      )
      ..cubicTo(
        c.dx + r * 0.7,
        c.dy - r,
        c.dx + r * 1.2,
        c.dy - r * 0.1,
        c.dx,
        c.dy + r * 0.65,
      )
      ..close();
    canvas.drawPath(path, paint);
  }

  void _drawSparkle(Canvas canvas, Offset c, double r, Paint paint) {
    final Path path = Path()
      ..moveTo(c.dx, c.dy - r)
      ..quadraticBezierTo(c.dx + r * 0.16, c.dy - r * 0.16, c.dx + r, c.dy)
      ..quadraticBezierTo(c.dx + r * 0.16, c.dy + r * 0.16, c.dx, c.dy + r)
      ..quadraticBezierTo(c.dx - r * 0.16, c.dy + r * 0.16, c.dx - r, c.dy)
      ..quadraticBezierTo(c.dx - r * 0.16, c.dy - r * 0.16, c.dx, c.dy - r)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_MascotPainter oldDelegate) =>
      oldDelegate.idle != idle ||
      oldDelegate.pop != pop ||
      oldDelegate.accent != accent ||
      oldDelegate.ink != ink;
}
