import 'dart:math';

enum PadSide { left, right }

/// Shared game loop state used by every MoveArcade game.
///
/// Squat Surfer and Sky Hopper reuse this unchanged — only the input that
/// triggers [registerHit] differs per game (a punch here, a squat or jump
/// there).
class GameEngine {
  static const double roundSeconds = 60;

  int score = 0;
  int combo = 0;
  int hits = 0;
  int misses = 0;
  double timeLeft = roundSeconds;

  PadSide active = PadSide.left;
  double _spawnAge = 0;
  final Random _rng = Random();

  bool get isRunning => timeLeft > 0;
  double get accuracy => (hits + misses) == 0 ? 0 : hits / (hits + misses);

  void start() {
    score = 0;
    combo = 0;
    hits = 0;
    misses = 0;
    timeLeft = roundSeconds;
    _spawn();
  }

  void _spawn() {
    active = _rng.nextBool() ? PadSide.left : PadSide.right;
    _spawnAge = 0;
  }

  void registerHit() {
    combo++;
    hits++;
    final mult = (1 + (combo - 1) * 0.25).clamp(1.0, 4.0);
    score += (100 * mult).round();
    _spawn();
  }

  void _miss() {
    combo = 0;
    misses++;
    _spawn();
  }

  /// Advance the clock. Returns true while the round is still running.
  bool tick(double dt) {
    timeLeft -= dt;
    _spawnAge += dt;
    if (_spawnAge > 2.6) _miss(); // un-hit target times out
    return isRunning;
  }
}
