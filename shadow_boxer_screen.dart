import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../../engine/calorie_engine.dart';
import '../../engine/game_engine.dart';
import '../../engine/pose_service.dart';
import 'punch_detector.dart';
import 'shadow_boxer_painter.dart';

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
    // Mirror horizontally for a natural selfie view.
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

    // calorie intensity = fastest hand speed normalised by diagonal
    final diag = _size.bottomRight(Offset.zero).distance;
    double maxSpeed = 0;
    if (l != null && _prevL != null) {
      maxSpeed = (l - _prevL!).distance / dt;
    }
    if (r != null && _prevR != null) {
      final rs = (r - _prevR!).distance / dt;
      if (rs > maxSpeed) maxSpeed = rs;
    }
    _calories.update(maxSpeed / diag, dt);
    _prevL = l;
    _prevR = r;

    // punch detection against the active pad
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
          // mirrored camera preview
          if (_pose.controller != null && _pose.controller!.value.isInitialized)
            Transform.flip(
              flipX: true,
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _pose.controller!.value.previewSize?.height ?? _size.width,
                  height: _pose.controller!.value.previewSize?.width ?? _size.height,
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
    Widget stat(String label, String value, [Color? color]) => Column(children: [
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
          stat('kcal', _calories.kcal.round().toString(), const Color(0xFFFFC24B)),
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
                  color: Colors.white, fontSize: 44, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          Text('${_engine.hits} punches · $acc% accuracy · ${_calories.kcal.round()} kcal',
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
            'Camera / pose failed to start:\n\n$_error\n\nCheck camera permissions in the OS settings and run on a physical device.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFFF8A8A), height: 1.5),
          ),
        ),
      );
}
