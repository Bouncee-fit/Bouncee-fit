// MoveArcade — Bouncee-fit / Shadow Boxer
// Entire app in one file so it's easy to add on GitHub.
import 'dart:io';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

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
      home: const StartScreen(),
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

// ---------------- Pose service (camera + ML Kit) ----------------
class PoseFrame {
  PoseFrame({this.leftWrist, this.rightWrist, this.arms = const []});
  final Offset? leftWrist;
  final Offset? rightWrist;
  final List<(Offset, Offset)> arms;
}

class PoseService {
  CameraController? controller;
  late final PoseDetector _detector;
  CameraDescription? _camera;
  bool _busy = false;
  final ValueNotifier<PoseFrame> frame = ValueNotifier(PoseFrame());

  Future<void> init() async {
    _detector = PoseDetector(options: PoseDetectorOptions());
    final cameras = await availableCameras();
    _camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
    controller = CameraController(
      _camera!,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );
    await controller!.initialize();
    await controller!.startImageStream(_process);
  }

  Future<void> _process(CameraImage image) async {
    if (_busy) return;
    _busy = true;
    try {
      final input = _toInputImage(image);
      if (input == null) return;
      final poses = await _detector.processImage(input);
      if (poses.isEmpty) {
        frame.value = PoseFrame();
        return;
      }
      final lm = poses.first.landmarks;
      final w = image.width.toDouble();
      final h = image.height.toDouble();
      Offset? norm(PoseLandmarkType t) {
        final p = lm[t];
        return p == null ? null : Offset(p.x / w, p.y / h);
      }
      final pts = {for (final t in PoseLandmarkType.values) t: norm(t)};
      final bones = <(Offset, Offset)>[];
      void bone(PoseLandmarkType a, PoseLandmarkType b) {
        if (pts[a] != null && pts[b] != null) bones.add((pts[a]!, pts[b]!));
      }
      bone(PoseLandmarkType.leftShoulder, PoseLandmarkType.leftElbow);
      bone(PoseLandmarkType.leftElbow, PoseLandmarkType.leftWrist);
      bone(PoseLandmarkType.rightShoulder, PoseLandmarkType.rightElbow);
      bone(PoseLandmarkType.rightElbow, PoseLandmarkType.rightWrist);
      bone(PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder);
      frame.value = PoseFrame(
        leftWrist: pts[PoseLandmarkType.leftWrist],
        rightWrist: pts[PoseLandmarkType.rightWrist],
        arms: bones,
      );
    } catch (e) {
      debugPrint('pose error: $e');
    } finally {
      _busy = false;
    }
  }

  InputImage? _toInputImage(CameraImage image) {
    final rotation =
        InputImageRotationValue.fromRawValue(_camera!.sensorOrientation) ??
            InputImageRotation.rotation0deg;
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;
    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  Future<void> dispose() async {
    await controller?.stopImageStream();
    await controller?.dispose();
    await _detector.close();
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
  final PoseService _pose = PoseService();
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
          if (_pose.controller != null &&
              _pose.controller!.value.isInitialized)
            Transform.flip(
              flipX: true,
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width:
                      _pose.controller!.value.previewSize?.height ?? _size.width,
                  height: _pose.controller!.value.previewSize?.width ??
                      _size.height,
                  child: CameraPreview(_pose.controller!),
                ),
              ),
            ),
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
