// MoveArcade — Bouncee-fit / Shadow Boxer
// Game + UI code. The camera + pose backend lives behind pose/pose_service.dart
// and is selected per platform (ML Kit on mobile, MediaPipe on web).
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'pose/pose_service.dart';

void main() => runApp(const MoveArcadeApp());

class MoveArcadeApp extends StatelessWidget {
  const MoveArcadeApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bouncee-fit — Shadow Boxer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFF2D78),
          brightness: Brightness.dark,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

// ---------------- Calorie model (deterministic) ----------------
class CalorieEngine {
  CalorieEngine(this.weightKg);
  double weightKg;
  double _met = 2.5;
  double kcal = 0;
  double get met => _met;
  void update(double normSpeed, double dt) {
    final target = (2.5 + normSpeed * 2.2).clamp(2.5, 8.0);
    _met += (target - _met) * 0.12;
    kcal += _met * 3.5 * weightKg / 200 / 60 * dt;
  }
  void reset() {
    _met = 2.5;
    kcal = 0;
  }
}

// ---------------- Shared game engine ----------------
enum PadSide { left, right }

class GameEngine {
  static const double roundSeconds = 60;
  int score = 0, combo = 0, hits = 0, misses = 0;
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
  bool tick(double dt) {
    timeLeft -= dt;
    _spawnAge += dt;
    if (_spawnAge > 2.6) _miss();
    return isRunning;
  }
}

// ---------------- Punch detector ----------------
class PunchDetector {
  Offset? _prevLeft, _prevRight;
  bool detect({
    required Offset? left,
    required Offset? right,
    required Offset padCenter,
    required double padRadius,
    required double minSpeed,
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

// ---------------- Temple Dash: difficulty ----------------
enum Difficulty { easy, moderate, high }

extension DifficultyConfig on Difficulty {
  String get label => switch (this) {
        Difficulty.easy => 'Easy',
        Difficulty.moderate => 'Moderate',
        Difficulty.high => 'High',
      };

  /// Forward speed at the start of a run (track-units / second).
  double get startSpeed => switch (this) {
        Difficulty.easy => 0.45,
        Difficulty.moderate => 0.60,
        Difficulty.high => 0.80,
      };

  /// How much the speed grows every second you survive.
  double get rampRate => switch (this) {
        Difficulty.easy => 0.010,
        Difficulty.moderate => 0.018,
        Difficulty.high => 0.028,
      };

  /// Speed cap so it stays (barely) playable.
  double get maxSpeed => switch (this) {
        Difficulty.easy => 1.4,
        Difficulty.moderate => 1.8,
        Difficulty.high => 2.3,
      };

  /// Seconds between obstacle spawns at the start (smaller = busier).
  double get startSpawnGap => switch (this) {
        Difficulty.easy => 1.50,
        Difficulty.moderate => 1.15,
        Difficulty.high => 0.90,
      };

  /// The busiest the spawns ever get as difficulty ramps.
  double get minSpawnGap => switch (this) {
        Difficulty.easy => 0.70,
        Difficulty.moderate => 0.55,
        Difficulty.high => 0.42,
      };
}

// ---------------- Temple Dash: engine ----------------
// What a track object is and how you avoid it.
enum DashKind {
  jumpBarrier, // sits on the ground -> JUMP over it
  slideBar, // hangs overhead       -> SQUAT / slide under it
  coin, // collectible          -> grab for points
}

class DashEntity {
  DashEntity(this.lane, this.kind, this.z);
  final int lane; // 0 left, 1 center, 2 right
  final DashKind kind;
  double z; // 1.0 far .. 0.0 at the player, negative once passed
  bool resolved = false; // collision/collection already handled
}

class TempleDashEngine {
  TempleDashEngine(this.difficulty) : speed = difficulty.startSpeed;
  final Difficulty difficulty;

  // --- tunable feel constants ---
  static const int laneCount = 3;
  static const double collisionZ = 0.06; // the player's plane along the track
  double zPerSpeed = 0.9; // how track depth maps to forward speed
  double jumpAirTime = 0.6; // seconds airborne per jump (match BodyController)
  double metresPerUnit = 10; // scales distance into a nicer-looking number
  int coinValue = 10; // points per coin

  // --- live state ---
  double speed;
  double distance = 0; // "metres"
  double runTime = 0; // seconds
  int coins = 0;
  bool alive = true;
  int playerLane = 1;
  double jumpT = 0; // remaining airtime
  bool sliding = false;
  double _spawnGap = 0;
  double _spawnTimer = 0;
  final List<DashEntity> entities = [];
  final Random _rng = Random();

  bool get isJumping => jumpT > 0;
  int get score => distance.round() + coins * coinValue;

  void start() {
    speed = difficulty.startSpeed;
    distance = 0;
    runTime = 0;
    coins = 0;
    alive = true;
    playerLane = 1;
    jumpT = 0;
    sliding = false;
    _spawnGap = difficulty.startSpawnGap;
    _spawnTimer = _spawnGap;
    entities.clear();
  }

  void _spawn() {
    final lane = _rng.nextInt(laneCount);
    final roll = _rng.nextDouble();
    final DashKind kind;
    if (roll < 0.35) {
      kind = DashKind.coin;
    } else if (roll < 0.68) {
      kind = DashKind.jumpBarrier;
    } else {
      kind = DashKind.slideBar;
    }
    entities.add(DashEntity(lane, kind, 1.0));
    // A collected coin feels better in a little trail.
    if (kind == DashKind.coin) {
      entities.add(DashEntity(lane, DashKind.coin, 1.10));
      entities.add(DashEntity(lane, DashKind.coin, 1.20));
    }
  }

  /// Advance the world one frame. [jump] is an edge event, [duck] is a level
  /// (held) signal, [lane] is the desired lane from the body controller.
  void tick(double dt,
      {required bool jump, required bool duck, required int lane}) {
    if (!alive) return;
    runTime += dt;

    // Survive longer -> faster and busier.
    speed = (speed + difficulty.rampRate * dt).clamp(0.0, difficulty.maxSpeed);
    _spawnGap = (difficulty.startSpawnGap - runTime * 0.02)
        .clamp(difficulty.minSpawnGap, difficulty.startSpawnGap);
    distance += speed * dt * metresPerUnit;

    // Player vertical state.
    playerLane = lane.clamp(0, laneCount - 1);
    sliding = duck;
    if (jump && jumpT <= 0 && !duck) jumpT = jumpAirTime;
    jumpT = (jumpT - dt).clamp(0.0, 999).toDouble();

    // Move every entity toward the player and resolve it as it crosses the
    // player's plane. Checking "z <= collisionZ" (not "== 0") means a big
    // step at high speed can't skip a collision.
    final dz = speed * dt * zPerSpeed;
    for (final e in entities) {
      e.z -= dz;
      if (!e.resolved && e.z <= collisionZ) {
        e.resolved = true;
        if (e.lane != playerLane) continue; // dodged into another lane
        switch (e.kind) {
          case DashKind.coin:
            coins++;
          case DashKind.jumpBarrier:
            if (!isJumping) alive = false;
          case DashKind.slideBar:
            if (!sliding) alive = false;
        }
      }
    }
    entities.removeWhere((e) => e.z < -0.12);

    _spawnTimer -= dt;
    if (_spawnTimer <= 0) {
      _spawn();
      _spawnTimer = _spawnGap;
    }
  }
}

// ---------------- Body controls (pose -> game input) ----------------
// One discrete control sample produced from a PoseFrame each tick.
class ControlState {
  ControlState({
    required this.jump,
    required this.duck,
    required this.lane,
    required this.intensity,
    this.tracking = false,
    this.hipY,
    this.baseHipY,
    this.centerX,
    this.baseCenterX,
  });
  final bool jump; // edge: true only on the frame a jump starts
  final bool duck; // level: true while the body is held low (slide)
  final int lane; // desired lane: 0 = left, 1 = center, 2 = right
  final double intensity; // 0..~1 amount of REAL body movement, for kcal
  final bool tracking; // whether a body was actually detected this frame
  // Debug read-outs, handy for an on-screen tuning overlay.
  final double? hipY, baseHipY, centerX, baseCenterX;
}

/// Translates raw pose landmarks into discrete game controls.
///
/// Detection is RELATIVE to a slowly-adapting neutral baseline, so it works for
/// any body size or camera distance. Every threshold below is public so you can
/// tune it live on a real phone. Coordinates are normalized 0..1; y grows
/// downward (so "hips rise" means hipY gets SMALLER).
class BodyController {
  // --- Adjustable thresholds (fractions of the frame, 0..1) ---
  /// Hips must rise this far above neutral to fire a JUMP.
  double jumpRiseThreshold = 0.06;

  /// Hips must drop this far below neutral to count as a SQUAT / DUCK.
  double duckDropThreshold = 0.06;

  /// Body center must shift this far sideways (in screen space) to LEAN/change
  /// lane.
  double leanThreshold = 0.07;

  /// How quickly the neutral baseline follows you while you stand centered
  /// (0 = frozen, 1 = instant). Only applied when you're NOT mid-gesture, so a
  /// held lean or squat never "becomes" the new neutral.
  double baselineEase = 0.04;

  /// Seconds the avatar stays airborne after one jump.
  double jumpAirTime = 0.6;

  /// Minimum seconds between jumps (debounce).
  double jumpCooldown = 0.45;

  // --- internal state ---
  double? _baseHipY;
  double? _baseCenterX;
  double _cooldown = 0;
  bool _wasRising = false; // edge tracking: one rise == one jump
  Map<PoseJoint, Offset> _prev = const {};

  void reset() {
    _baseHipY = null;
    _baseCenterX = null;
    _cooldown = 0;
    _wasRising = false;
    _prev = const {};
  }

  // ---- geometry helpers ----
  double? _avg(Map<PoseJoint, Offset> p, List<PoseJoint> ts,
      bool useY) {
    var sum = 0.0;
    var n = 0;
    for (final t in ts) {
      final o = p[t];
      if (o != null) {
        sum += useY ? o.dy : o.dx;
        n++;
      }
    }
    return n == 0 ? null : sum / n;
  }

  /// Vertical position of the hips (0 top .. 1 bottom), falling back to
  /// shoulders then nose when the hips aren't visible.
  double? hipHeight(Map<PoseJoint, Offset> p) =>
      _avg(p, [PoseJoint.leftHip, PoseJoint.rightHip], true) ??
      _avg(p, [PoseJoint.leftShoulder, PoseJoint.rightShoulder],
          true) ??
      _avg(p, [PoseJoint.nose], true);

  /// Horizontal body center in SCREEN space (mirrored to match the selfie
  /// preview), so shifting toward the right of the screen maps to lane-right.
  double? bodyCenterX(Map<PoseJoint, Offset> p) {
    final x = _avg(p, [
      PoseJoint.leftShoulder,
      PoseJoint.rightShoulder,
      PoseJoint.leftHip,
      PoseJoint.rightHip,
    ], false);
    return x == null ? null : 1 - x; // mirror to match the flipped preview
  }

  // ---- named gesture tests (relative to the neutral baseline) ----
  bool isRising(double hipY) =>
      _baseHipY != null && hipY < _baseHipY! - jumpRiseThreshold;

  bool isSquatting(double hipY) =>
      _baseHipY != null && hipY > _baseHipY! + duckDropThreshold;

  int leanLane(double centerX) {
    if (_baseCenterX == null) return 1;
    final d = centerX - _baseCenterX!;
    if (d > leanThreshold) return 2; // leaning to screen-right
    if (d < -leanThreshold) return 0; // leaning to screen-left
    return 1; // centered
  }

  /// Average per-second motion of the tracked joints. This is what feeds the
  /// calorie model, so kcal comes from REAL effort, not the game scroll speed.
  double _movement(Map<PoseJoint, Offset> p, double dt) {
    if (dt <= 0 || _prev.isEmpty) return 0;
    const joints = [
      PoseJoint.leftWrist,
      PoseJoint.rightWrist,
      PoseJoint.leftHip,
      PoseJoint.rightHip,
      PoseJoint.leftAnkle,
      PoseJoint.rightAnkle,
      PoseJoint.nose,
    ];
    var sum = 0.0;
    var n = 0;
    for (final t in joints) {
      final a = p[t];
      final b = _prev[t];
      if (a != null && b != null) {
        sum += (a - b).distance / dt;
        n++;
      }
    }
    return n == 0 ? 0 : sum / n;
  }

  /// Produce one control sample from the latest pose frame.
  ControlState update(PoseFrame frame, double dt) {
    _cooldown = (_cooldown - dt).clamp(0, 999).toDouble();
    final p = frame.points;
    final hipY = hipHeight(p);
    final centerX = bodyCenterX(p);
    final intensity = _movement(p, dt);
    _prev = p;

    if (hipY == null || centerX == null) {
      _wasRising = false;
      return ControlState(
          jump: false, duck: false, lane: 1, intensity: intensity);
    }

    // Seed the baseline on the first good frame.
    _baseHipY ??= hipY;
    _baseCenterX ??= centerX;

    final squatting = isSquatting(hipY);
    final rising = isRising(hipY);
    final lane = leanLane(centerX);

    // Only drift the neutral baseline when standing centered & upright, so a
    // held lane-lean or duck doesn't slowly cancel itself out.
    if (!squatting && !rising && lane == 1) {
      _baseHipY = _baseHipY! + (hipY - _baseHipY!) * baselineEase;
      _baseCenterX = _baseCenterX! + (centerX - _baseCenterX!) * baselineEase;
    }

    // Jump fires once on the rising edge, never while squatting, with a
    // cooldown so a single hop isn't read as several jumps.
    var jump = false;
    if (rising && !_wasRising && !squatting && _cooldown <= 0) {
      jump = true;
      _cooldown = jumpCooldown;
    }
    _wasRising = rising;

    return ControlState(
      jump: jump,
      duck: squatting,
      lane: lane,
      intensity: intensity,
      tracking: true,
      hipY: hipY,
      baseHipY: _baseHipY,
      centerX: centerX,
      baseCenterX: _baseCenterX,
    );
  }
}

// ---------------- Painter ----------------
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
  final List<Offset> hands;
  final List<(Offset, Offset)> arms;
  static const pad = Color(0xFFFF2D78);
  static const padDim = Color(0xFF5A1838);
  static const hand = Color(0xFFFFC24B);
  static const good = Color(0xFF27D3A2);
  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide * 0.12;
    final y = size.height * 0.40;
    _pad(canvas, Offset(size.width * 0.27, y), r, 'L',
        active == PadSide.left || flashLeft);
    _pad(canvas, Offset(size.width * 0.73, y), r, 'R',
        active == PadSide.right || flashRight);
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
    canvas.drawCircle(c, r,
        Paint()..color = (lit ? pad : padDim).withOpacity(lit ? 0.22 : 0.18));
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

// ---------------- Temple Dash painter ----------------
class TempleDashPainter extends CustomPainter {
  TempleDashPainter({
    required this.entities,
    required this.avatarLane, // continuous 0..2 for smooth lane gliding
    required this.jumpArc, // 0 = on the ground .. 1 = top of the jump
    required this.sliding,
  });
  final List<DashEntity> entities;
  final double avatarLane;
  final double jumpArc;
  final bool sliding;

  static const _track = Color(0xFF11202E);
  static const _rail = Color(0xFF3CE0C5);
  static const _lane = Color(0x553CE0C5);
  static const _barrier = Color(0xFFFF4D6D); // jump over (on the ground)
  static const _bar = Color(0xFFFFB23E); // slide under (overhead)
  static const _coin = Color(0xFFFFD43B);
  static const _avatar = Color(0xFF5BE0FF);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final horizonY = h * 0.30, bottomY = h * 0.98, vanishX = w / 2;
    final laneHalf = w * 0.30;

    // Perspective mapping: e = 0 at the far horizon, 1 right in front of you.
    double depth(double z) => (1 - z).clamp(0.0, 1.0);
    double scaleOf(double e) => 0.15 + 0.85 * e;
    double yOf(double e) => horizonY + (bottomY - horizonY) * e;
    double xOf(double lane, double e) =>
        vanishX + (lane - 1) * laneHalf * scaleOf(e);

    // --- track surface ---
    final surface = Path()
      ..moveTo(xOf(-0.5, 0), yOf(0))
      ..lineTo(xOf(2.5, 0), yOf(0))
      ..lineTo(xOf(2.5, 1), yOf(1))
      ..lineTo(xOf(-0.5, 1), yOf(1))
      ..close();
    canvas.drawPath(surface, Paint()..color = _track.withOpacity(0.55));

    // lane dividers + outer rails
    void rail(double lane, Color c, double width) {
      canvas.drawLine(
        Offset(xOf(lane, 0), yOf(0)),
        Offset(xOf(lane, 1), yOf(1)),
        Paint()
          ..color = c
          ..strokeWidth = width,
      );
    }

    rail(0.5, _lane, 2);
    rail(1.5, _lane, 2);
    rail(-0.5, _rail, 4);
    rail(2.5, _rail, 4);

    // --- entities, far first so near ones overlap them ---
    final sorted = [...entities]..sort((a, b) => b.z.compareTo(a.z));
    for (final e in sorted) {
      final ee = depth(e.z);
      final s = scaleOf(ee);
      final x = xOf(e.lane.toDouble(), ee);
      final groundY = yOf(ee);
      switch (e.kind) {
        case DashKind.coin:
          if (e.resolved) break; // collected -> gone
          final cy = groundY - 0.06 * h * s;
          canvas.drawCircle(
              Offset(x, cy), 14 * s, Paint()..color = _coin.withOpacity(0.95));
          canvas.drawCircle(
              Offset(x, cy),
              14 * s,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 3 * s
                ..color = const Color(0xFFB8860B));
        case DashKind.jumpBarrier:
          final bh = 0.12 * h * s, bw = laneHalf * s * 0.8;
          final rect = Rect.fromLTWH(x - bw / 2, groundY - bh, bw, bh);
          canvas.drawRRect(
              RRect.fromRectAndRadius(rect, Radius.circular(6 * s)),
              Paint()..color = _barrier.withOpacity(0.92));
        case DashKind.slideBar:
          final bw = laneHalf * s * 0.95, bh = 0.045 * h * s;
          final barY = groundY - 0.17 * h * s; // hangs overhead -> duck under
          final rect = Rect.fromLTWH(x - bw / 2, barY, bw, bh);
          canvas.drawRRect(
              RRect.fromRectAndRadius(rect, Radius.circular(4 * s)),
              Paint()..color = _bar.withOpacity(0.92));
      }
    }

    // --- the avatar (always near the bottom, in its current lane) ---
    final ax = xOf(avatarLane, 1.0);
    final groundY = yOf(1.0);
    final lift = jumpArc * 0.18 * h;

    // ground shadow shrinks as you jump
    canvas.drawOval(
      Rect.fromCenter(
          center: Offset(ax, groundY),
          width: 0.12 * w * (1 - 0.4 * jumpArc),
          height: 0.025 * h * (1 - 0.4 * jumpArc)),
      Paint()..color = Colors.black.withOpacity(0.35),
    );

    final body = Paint()..color = _avatar;
    if (sliding) {
      // low and wide
      final bw = 0.13 * w, bh = 0.06 * h;
      final rect = Rect.fromLTWH(ax - bw / 2, groundY - bh, bw, bh);
      canvas.drawRRect(
          RRect.fromRectAndRadius(rect, Radius.circular(0.03 * h)), body);
    } else {
      final bw = 0.08 * w, bh = 0.14 * h;
      final top = groundY - bh - lift;
      final rect = Rect.fromLTWH(ax - bw / 2, top, bw, bh);
      canvas.drawRRect(
          RRect.fromRectAndRadius(rect, Radius.circular(0.02 * h)), body);
      // head
      canvas.drawCircle(Offset(ax, top - 0.025 * h), 0.025 * h, body);
    }
  }

  @override
  bool shouldRepaint(covariant TempleDashPainter old) => true;
}

// ---------------- Start screen ----------------
class StartScreen extends StatefulWidget {
  const StartScreen({super.key});
  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  final _weight = TextEditingController(text: '70');
  void _start() {
    final w = double.tryParse(_weight.text)?.clamp(30, 200) ?? 70;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ShadowBoxerScreen(weightKg: w.toDouble()),
    ));
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E14),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('BOUNCEE-FIT',
                style: TextStyle(
                    color: Color(0xFFFF2D78), letterSpacing: 5, fontSize: 12)),
            const SizedBox(height: 12),
            const Text('Shadow Boxer',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 52,
                    fontWeight: FontWeight.w900)),
            const SizedBox(height: 14),
            const SizedBox(
              width: 360,
              child: Text(
                'A pad lights up — punch it. Your real fists are the controller. '
                '60-second round. Pose runs on-device; nothing is uploaded.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF8AA0B3), height: 1.6),
              ),
            ),
            const SizedBox(height: 28),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Text('Your weight ',
                  style: TextStyle(color: Color(0xFF8AA0B3))),
              SizedBox(
                width: 70,
                child: TextField(
                  controller: _weight,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    isDense: true,
                    enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1F2B38))),
                  ),
                ),
              ),
              const Text('  kg', style: TextStyle(color: Color(0xFF8AA0B3))),
            ]),
            const SizedBox(height: 24),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF27D3A2),
                  foregroundColor: const Color(0xFF06090D),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 30, vertical: 16)),
              onPressed: _start,
              child: const Text('Start round'),
            ),
          ]),
        ),
      ),
    );
  }
}

// ---------------- Game screen ----------------
class ShadowBoxerScreen extends StatefulWidget {
  const ShadowBoxerScreen({super.key, required this.weightKg});
  final double weightKg;
  @override
  State<ShadowBoxerScreen> createState() => _ShadowBoxerScreenState();
}

class _ShadowBoxerScreenState extends State<ShadowBoxerScreen>
    with SingleTickerProviderStateMixin {
  final PoseService _pose = createPoseService();
  final GameEngine _engine = GameEngine();
  final PunchDetector _detector = PunchDetector();
  late final CalorieEngine _calories = CalorieEngine(widget.weightKg);
  late final Ticker _ticker;
  Duration _lastElapsed = Duration.zero;
  Size _size = Size.zero;
  bool _ready = false;
  bool _ended = false;
  String? _error;
  List<Offset> _hands = [];
  List<(Offset, Offset)> _arms = [];
  Offset? _prevL, _prevR;
  DateTime _flashL = DateTime(0), _flashR = DateTime(0);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _boot();
  }

  Future<void> _boot() async {
    try {
      await _pose.init();
      _engine.start();
      setState(() => _ready = true);
      _ticker.start();
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Offset? _toScreen(Offset? norm) {
    if (norm == null || _size == Size.zero) return null;
    return Offset((1 - norm.dx) * _size.width, norm.dy * _size.height);
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastElapsed).inMicroseconds / 1e6;
    _lastElapsed = elapsed;
    if (dt <= 0 || _size == Size.zero) return;
    final frame = _pose.frame.value;
    final l = _toScreen(frame.leftWrist);
    final r = _toScreen(frame.rightWrist);
    _hands = [l, r].whereType<Offset>().toList();
    _arms = frame.arms
        .map((b) => (_toScreen(b.$1)!, _toScreen(b.$2)!))
        .toList();
    final diag = _size.bottomRight(Offset.zero).distance;
    double maxSpeed = 0;
    if (l != null && _prevL != null) maxSpeed = (l - _prevL!).distance / dt;
    if (r != null && _prevR != null) {
      final rs = (r - _prevR!).distance / dt;
      if (rs > maxSpeed) maxSpeed = rs;
    }
    _calories.update(maxSpeed / diag, dt);
    _prevL = l;
    _prevR = r;
    final padY = _size.height * 0.40;
    final padCenter = _engine.active == PadSide.left
        ? Offset(_size.width * 0.27, padY)
        : Offset(_size.width * 0.73, padY);
    final hit = _detector.detect(
      left: l,
      right: r,
      padCenter: padCenter,
      padRadius: _size.shortestSide * 0.12,
      minSpeed: _size.shortestSide * 0.6,
      dt: dt,
    );
    if (hit) {
      if (_engine.active == PadSide.left) {
        _flashL = DateTime.now().add(const Duration(milliseconds: 160));
      } else {
        _flashR = DateTime.now().add(const Duration(milliseconds: 160));
      }
      _engine.registerHit();
    }
    if (!_engine.tick(dt)) {
      _ticker.stop();
      setState(() => _ended = true);
      return;
    }
    setState(() {});
  }

  void _restart() {
    _engine.start();
    _calories.reset();
    _detector.reset();
    _lastElapsed = Duration.zero;
    setState(() => _ended = false);
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _pose.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Scaffold(
      backgroundColor: const Color(0xFF06090D),
      body: LayoutBuilder(builder: (context, c) {
        _size = Size(c.maxWidth, c.maxHeight);
        if (_error != null) return _errorView();
        if (!_ready) {
          return const Center(
              child: Text('Starting camera…',
                  style: TextStyle(color: Colors.white70)));
        }
        return Stack(fit: StackFit.expand, children: [
          // Live camera feed for the current platform (ML Kit camera on
          // mobile, MediaPipe <video> on web). Fills the Stack via
          // StackFit.expand.
          _pose.buildPreview(context),
          Container(color: Colors.black.withOpacity(0.45)),
          CustomPaint(
            painter: BoxerPainter(
              active: _engine.active,
              flashLeft: now.isBefore(_flashL),
              flashRight: now.isBefore(_flashR),
              hands: _hands,
              arms: _arms,
            ),
          ),
          _hud(),
          if (_ended) _endOverlay(),
        ]);
      }),
    );
  }

  Widget _hud() {
    final t = _engine.timeLeft.ceil().clamp(0, 60);
    Widget stat(String label, String value, [Color? color]) =>
        Column(children: [
          Text(label.toUpperCase(),
              style: const TextStyle(
                  color: Color(0xFF7E94A8), fontSize: 11, letterSpacing: 2)),
          const SizedBox(height: 2),
          Text(value,
              style: TextStyle(
                  color: color ?? Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w800)),
        ]);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          stat('score', _engine.score.toString()),
          stat('time', '0:${t.toString().padLeft(2, '0')}'),
          stat('kcal', _calories.kcal.round().toString(),
              const Color(0xFFFFC24B)),
        ]),
      ),
    );
  }

  Widget _endOverlay() {
    final acc = (_engine.accuracy * 100).round();
    return Container(
      color: Colors.black.withOpacity(0.82),
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('ROUND COMPLETE',
              style: TextStyle(
                  color: Color(0xFFFF2D78), letterSpacing: 4, fontSize: 12)),
          const SizedBox(height: 14),
          Text('${_engine.score}  pts',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 44,
                  fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          Text(
              '${_engine.hits} punches · $acc% accuracy · ${_calories.kcal.round()} kcal',
              style: const TextStyle(color: Color(0xFF8AA0B3), fontSize: 15)),
          const SizedBox(height: 26),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF27D3A2),
                foregroundColor: const Color(0xFF06090D)),
            onPressed: _restart,
            child: const Text('Play again'),
          ),
        ]),
      ),
    );
  }

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            'Camera / pose failed to start:\n\n$_error\n\nCheck camera permission in Settings and run on a real phone.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFFF8A8A), height: 1.5),
          ),
        ),
      );
}

// ---------------- Home menu ----------------
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    Widget gameCard({
      required String tag,
      required String title,
      required String blurb,
      required Color accent,
      required VoidCallback onTap,
    }) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          width: 360,
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF111A24),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: accent.withOpacity(0.5), width: 1.5),
          ),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tag,
                style:
                    TextStyle(color: accent, letterSpacing: 3, fontSize: 11)),
            const SizedBox(height: 6),
            Text(title,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            Text(blurb,
                style: const TextStyle(
                    color: Color(0xFF8AA0B3), height: 1.5, fontSize: 13)),
          ]),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E14),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('BOUNCEE-FIT',
                  style: TextStyle(
                      color: Color(0xFFFF2D78), letterSpacing: 5, fontSize: 12)),
              const SizedBox(height: 8),
              const Text('Move Arcade',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 40,
                      fontWeight: FontWeight.w900)),
              const SizedBox(height: 4),
              const Text('Your body is the controller',
                  style: TextStyle(color: Color(0xFF8AA0B3))),
              const SizedBox(height: 28),
              gameCard(
                tag: 'BOXING',
                title: 'Shadow Boxer',
                blurb:
                    'A pad lights up — punch it with your real fists. 60-second round.',
                accent: const Color(0xFFFF2D78),
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const StartScreen())),
              ),
              gameCard(
                tag: 'ENDLESS RUNNER',
                title: 'Temple Dash',
                blurb:
                    'Auto-run a 3-lane track. JUMP, SQUAT and LEAN with your whole body to dodge obstacles and grab coins.',
                accent: const Color(0xFF3CE0C5),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const TempleDashSetupScreen())),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ---------------- Temple Dash: pre-run setup (difficulty + weight) ----------------
class TempleDashSetupScreen extends StatefulWidget {
  const TempleDashSetupScreen({super.key});
  @override
  State<TempleDashSetupScreen> createState() => _TempleDashSetupScreenState();
}

class _TempleDashSetupScreenState extends State<TempleDashSetupScreen> {
  final _weight = TextEditingController(text: '70');
  Difficulty _difficulty = Difficulty.moderate;

  void _start() {
    final w = double.tryParse(_weight.text)?.clamp(30, 200) ?? 70;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          TempleDashScreen(weightKg: w.toDouble(), difficulty: _difficulty),
    ));
  }

  @override
  Widget build(BuildContext context) {
    Widget diffChip(Difficulty d) {
      final sel = _difficulty == d;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _difficulty = d),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: sel ? const Color(0xFF3CE0C5) : const Color(0xFF111A24),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: const Color(0xFF3CE0C5).withOpacity(sel ? 1 : 0.4)),
            ),
            child: Text(d.label,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: sel ? const Color(0xFF06090D) : Colors.white,
                    fontWeight: FontWeight.w700)),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E14),
      appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          elevation: 0),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('TEMPLE DASH',
                style: TextStyle(
                    color: Color(0xFF3CE0C5), letterSpacing: 4, fontSize: 12)),
            const SizedBox(height: 10),
            const Text('Pick your pace',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 34,
                    fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            const SizedBox(
              width: 360,
              child: Text(
                'JUMP to clear barriers · SQUAT to slide under bars · LEAN '
                'left/right to switch lanes and grab coins. One life — survive '
                'as long as you can.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF8AA0B3), height: 1.6),
              ),
            ),
            const SizedBox(height: 24),
            const SizedBox(
              width: 360,
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Difficulty',
                      style: TextStyle(color: Color(0xFF8AA0B3)))),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: 360,
              child: Row(children: [
                diffChip(Difficulty.easy),
                diffChip(Difficulty.moderate),
                diffChip(Difficulty.high),
              ]),
            ),
            const SizedBox(height: 22),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Text('Your weight ',
                  style: TextStyle(color: Color(0xFF8AA0B3))),
              SizedBox(
                width: 70,
                child: TextField(
                  controller: _weight,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    isDense: true,
                    enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1F2B38))),
                  ),
                ),
              ),
              const Text('  kg', style: TextStyle(color: Color(0xFF8AA0B3))),
            ]),
            const SizedBox(height: 26),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF3CE0C5),
                  foregroundColor: const Color(0xFF06090D),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 30, vertical: 16)),
              onPressed: _start,
              child: const Text('Start run'),
            ),
          ]),
        ),
      ),
    );
  }
}

// ---------------- Temple Dash: the game ----------------
class TempleDashScreen extends StatefulWidget {
  const TempleDashScreen(
      {super.key, required this.weightKg, required this.difficulty});
  final double weightKg;
  final Difficulty difficulty;
  @override
  State<TempleDashScreen> createState() => _TempleDashScreenState();
}

class _TempleDashScreenState extends State<TempleDashScreen>
    with SingleTickerProviderStateMixin {
  final PoseService _pose = createPoseService();
  final BodyController _body = BodyController();
  late final TempleDashEngine _engine = TempleDashEngine(widget.difficulty);
  late final CalorieEngine _calories = CalorieEngine(widget.weightKg);
  late final Ticker _ticker;

  Duration _lastElapsed = Duration.zero;
  Size _size = Size.zero;
  bool _ready = false;
  bool _ended = false;
  String? _error;

  double _avatarLane = 1; // eased, continuous lane for smooth rendering
  double _countdown = 3.0; // calibration / get-ready before the run starts
  bool _tracking = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _boot();
  }

  Future<void> _boot() async {
    try {
      await _pose.init();
      _engine.start();
      setState(() => _ready = true);
      _ticker.start();
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastElapsed).inMicroseconds / 1e6;
    _lastElapsed = elapsed;
    if (dt <= 0 || _size == Size.zero) return;

    // Read the body every frame: this seeds/settles the neutral baseline and
    // keeps the calorie count tied to real movement.
    final control = _body.update(_pose.frame.value, dt);
    _tracking = control.tracking;
    _calories.update(control.intensity, dt);

    // Give the player a few seconds to get in frame and stand centered so the
    // neutral baseline is calibrated before obstacles appear.
    if (_countdown > 0) {
      _countdown -= dt;
      setState(() {});
      return;
    }

    _engine.tick(dt,
        jump: control.jump, duck: control.duck, lane: control.lane);

    // Glide the drawn avatar toward its target lane (frame-rate independent).
    _avatarLane += (_engine.playerLane - _avatarLane) * (1 - exp(-12 * dt));

    if (!_engine.alive) {
      _ticker.stop();
      setState(() => _ended = true);
      return;
    }
    setState(() {});
  }

  // Smooth up-and-over arc, 0 on the ground .. 1 at the peak.
  double get _jumpArc {
    if (_engine.jumpT <= 0) return 0;
    final frac = (_engine.jumpT / _engine.jumpAirTime).clamp(0.0, 1.0);
    return sin(frac * pi);
  }

  void _restart() {
    _engine.start();
    _calories.reset();
    _body.reset();
    _avatarLane = 1;
    _countdown = 3.0;
    _lastElapsed = Duration.zero;
    setState(() => _ended = false);
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _pose.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF06090D),
      body: LayoutBuilder(builder: (context, c) {
        _size = Size(c.maxWidth, c.maxHeight);
        if (_error != null) return _errorView();
        if (!_ready) {
          return const Center(
              child: Text('Starting camera…',
                  style: TextStyle(color: Colors.white70)));
        }
        return Stack(fit: StackFit.expand, children: [
          // Live camera feed for the current platform (ML Kit camera on
          // mobile, MediaPipe <video> on web). Fills the Stack via
          // StackFit.expand.
          _pose.buildPreview(context),
          Container(color: Colors.black.withOpacity(0.50)),
          CustomPaint(
            painter: TempleDashPainter(
              entities: _engine.entities,
              avatarLane: _avatarLane,
              jumpArc: _jumpArc,
              sliding: _engine.sliding,
            ),
          ),
          _hud(),
          if (_countdown > 0) _countdownOverlay(),
          if (_countdown <= 0 && !_tracking && !_ended) _trackingHint(),
          if (_ended) _endOverlay(),
        ]);
      }),
    );
  }

  Widget _hud() {
    Widget stat(String label, String value, [Color? color]) =>
        Column(children: [
          Text(label.toUpperCase(),
              style: const TextStyle(
                  color: Color(0xFF7E94A8), fontSize: 11, letterSpacing: 2)),
          const SizedBox(height: 2),
          Text(value,
              style: TextStyle(
                  color: color ?? Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w800)),
        ]);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        child:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          stat('dist', '${_engine.distance.round()}m'),
          stat('coins', _engine.coins.toString(), const Color(0xFFFFD43B)),
          stat('kcal', _calories.kcal.round().toString(),
              const Color(0xFFFFC24B)),
        ]),
      ),
    );
  }

  Widget _countdownOverlay() {
    final n = _countdown.ceil();
    return Container(
      color: Colors.black.withOpacity(0.5),
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('STAND CENTERED IN FRAME',
              style: TextStyle(
                  color: Color(0xFF3CE0C5), letterSpacing: 3, fontSize: 13)),
          const SizedBox(height: 10),
          Text('$n',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 80,
                  fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          Text(_tracking ? 'Body detected ✓' : 'Step back so I can see you',
              style: TextStyle(
                  color: _tracking
                      ? const Color(0xFF27D3A2)
                      : const Color(0xFFFF8A8A))),
        ]),
      ),
    );
  }

  Widget _trackingHint() => Positioned(
        bottom: 30,
        left: 0,
        right: 0,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(20)),
            child: const Text('Step into frame',
                style: TextStyle(color: Color(0xFFFF8A8A))),
          ),
        ),
      );

  Widget _endOverlay() {
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(label,
                style: const TextStyle(color: Color(0xFF8AA0B3), fontSize: 15)),
            Text(value,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
          ]),
        );
    return Container(
      color: Colors.black.withOpacity(0.85),
      child: Center(
        child: SizedBox(
          width: 320,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('RUN OVER',
                style: TextStyle(
                    color: Color(0xFF3CE0C5), letterSpacing: 4, fontSize: 12)),
            const SizedBox(height: 12),
            Text('${_engine.score}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 52,
                    fontWeight: FontWeight.w900)),
            const Text('points',
                style: TextStyle(color: Color(0xFF8AA0B3), fontSize: 13)),
            const SizedBox(height: 18),
            row('Distance', '${_engine.distance.round()} m'),
            row('Coins', '${_engine.coins}'),
            row('Time', '${_engine.runTime.round()} s'),
            row('Calories', '${_calories.kcal.round()} kcal'),
            row('Difficulty', widget.difficulty.label),
            const SizedBox(height: 22),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Color(0xFF1F2B38))),
                onPressed: () =>
                    Navigator.of(context).popUntil((r) => r.isFirst),
                child: const Text('Home'),
              ),
              const SizedBox(width: 12),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF3CE0C5),
                    foregroundColor: const Color(0xFF06090D)),
                onPressed: _restart,
                child: const Text('Play again'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            'Camera / pose failed to start:\n\n$_error\n\nCheck camera permission in Settings and run on a real phone.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFFF8A8A), height: 1.5),
          ),
        ),
      );
}
