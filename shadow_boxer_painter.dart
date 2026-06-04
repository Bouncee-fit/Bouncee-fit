import 'package:flutter/material.dart';
import '../../engine/game_engine.dart';

class BoxerPainter extends CustomPainter {
  BoxerPainter({
    required this.active,
    required this.flashLeft,
    required this.flashRight,
    required this.hands,
    required this.arms,
  });

  final PadSide active;
  final bool flashLeft;
  final bool flashRight;
  final List<Offset> hands; // screen px
  final List<(Offset, Offset)> arms; // screen px

  static const pad = Color(0xFFFF2D78);
  static const padDim = Color(0xFF5A1838);
  static const hand = Color(0xFFFFC24B);
  static const good = Color(0xFF27D3A2);

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide * 0.12;
    final y = size.height * 0.40;
    final left = Offset(size.width * 0.27, y);
    final right = Offset(size.width * 0.73, y);

    _pad(canvas, left, r, 'L', active == PadSide.left || flashLeft);
    _pad(canvas, right, r, 'R', active == PadSide.right || flashRight);

    final bone = Paint()
      ..color = good.withOpacity(0.55)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    for (final (a, b) in arms) {
      canvas.drawLine(a, b, bone);
    }

    final fill = Paint()..color = hand.withOpacity(0.95);
    final ring = Paint()
      ..color = hand.withOpacity(0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    for (final h in hands) {
      canvas.drawCircle(h, 16, fill);
      canvas.drawCircle(h, 26, ring);
    }
  }

  void _pad(Canvas canvas, Offset c, double r, String label, bool lit) {
    canvas.drawCircle(
        c, r, Paint()..color = (lit ? pad : padDim).withOpacity(lit ? 0.22 : 0.18));
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = lit ? 6 : 2
          ..color = lit ? pad : padDim);
    final tp = TextPainter(
      text: TextSpan(
          text: label,
          style: TextStyle(
              color: lit ? const Color(0xFFFFD6E6) : const Color(0xFF7E94A8),
              fontSize: 22,
              fontWeight: FontWeight.w600)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant BoxerPainter old) => true;
}
