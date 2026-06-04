import 'package:flutter/widgets.dart';

/// Detects a punch: a wrist entering the target pad zone with enough velocity.
/// This is the only game-specific input rule for Shadow Boxer — Squat Surfer
/// and Sky Hopper swap in their own detector against the same engine.
class PunchDetector {
  Offset? _prevLeft;
  Offset? _prevRight;

  /// All positions in screen pixels. Returns true on a registered punch.
  bool detect({
    required Offset? left,
    required Offset? right,
    required Offset padCenter,
    required double padRadius,
    required double minSpeed, // px/sec
    required double dt,
  }) {
    final hit = _check(left, _prevLeft, padCenter, padRadius, minSpeed, dt) ||
        _check(right, _prevRight, padCenter, padRadius, minSpeed, dt);
    _prevLeft = left;
    _prevRight = right;
    return hit;
  }

  bool _check(Offset? cur, Offset? prev, Offset center, double radius,
      double minSpeed, double dt) {
    if (cur == null || prev == null || dt <= 0) return false;
    final inside = (cur - center).distance < radius;
    final speed = (cur - prev).distance / dt;
    return inside && speed > minSpeed;
  }

  void reset() {
    _prevLeft = null;
    _prevRight = null;
  }
}
