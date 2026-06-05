// ---------------- Web pose backend: MediaPipe Tasks Vision ----------------
// Used in the browser. Google ML Kit has no web support, so this backend talks
// to the MediaPipe pose landmarker running in JS (see web/mediapipe_pose.js)
// over JS interop. It produces the exact same PoseFrame as the mobile backend,
// in the same coordinate convention, so the games don't know the difference.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'pose_service.dart';

PoseService createPoseService() => WebPoseService();

// --- JS interop into window.bouncee (defined by web/mediapipe_pose.js) ---
@JS('bouncee.init')
external JSPromise<JSBoolean> _jsInit();

@JS('bouncee.latest')
external JSString? _jsLatest();

@JS('bouncee.video')
external web.HTMLVideoElement? _jsVideo();

@JS('bouncee.stop')
external void _jsStop();

const _viewType = 'bouncee-mediapipe-video';
bool _factoryRegistered = false;

class WebPoseService implements PoseService {
  @override
  final ValueNotifier<PoseFrame> frame = ValueNotifier(PoseFrame());

  Timer? _poll;

  // MediaPipe BlazePose landmark index -> the joints the games use.
  static const _indexToJoint = <int, PoseJoint>{
    0: PoseJoint.nose,
    11: PoseJoint.leftShoulder,
    12: PoseJoint.rightShoulder,
    13: PoseJoint.leftElbow,
    14: PoseJoint.rightElbow,
    15: PoseJoint.leftWrist,
    16: PoseJoint.rightWrist,
    23: PoseJoint.leftHip,
    24: PoseJoint.rightHip,
    27: PoseJoint.leftAnkle,
    28: PoseJoint.rightAnkle,
  };

  @override
  Future<void> init() async {
    // Loads the model + opens the webcam; throws if the user denies permission.
    await _jsInit().toDart;

    if (!_factoryRegistered) {
      ui_web.platformViewRegistry.registerViewFactory(
        _viewType,
        (int viewId) => _jsVideo() ?? web.document.createElement('div'),
      );
      _factoryRegistered = true;
    }

    // The JS loop writes the newest landmarks; republish them as PoseFrame at
    // ~60fps so the game's ValueNotifier-driven reads stay fresh.
    _poll = Timer.periodic(const Duration(milliseconds: 16), (_) => _pump());
  }

  void _pump() {
    final raw = _jsLatest()?.toDart;
    if (raw == null) return;
    final data = jsonDecode(raw) as Map<String, dynamic>;
    if (data['present'] != true) {
      frame.value = PoseFrame();
      return;
    }
    final lms = data['landmarks'] as List<dynamic>;
    final pts = <PoseJoint, Offset>{};
    _indexToJoint.forEach((index, joint) {
      if (index < lms.length) {
        final lm = lms[index] as Map<String, dynamic>;
        // MediaPipe normalized coords already match our convention: x,y in
        // 0..1, origin top-left, y growing downward, unmirrored.
        pts[joint] = Offset(
          (lm['x'] as num).toDouble(),
          (lm['y'] as num).toDouble(),
        );
      }
    });
    frame.value = PoseFrame.fromPoints(pts);
  }

  @override
  Widget buildPreview(BuildContext context) =>
      const HtmlElementView(viewType: _viewType);

  @override
  Future<void> dispose() async {
    _poll?.cancel();
    _jsStop();
  }
}
