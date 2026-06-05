// ---------------- Pose service: platform-neutral abstraction ----------------
//
// The game talks only to this file. The concrete backend is chosen at compile
// time by the conditional import below:
//
//   * Android / iOS  -> pose_service_mobile.dart  (Google ML Kit + camera)
//   * Web (browser)  -> pose_service_web.dart      (MediaPipe Tasks Vision)
//
// Both backends produce the SAME [PoseFrame] in the SAME coordinate convention
// (normalized 0..1, y growing downward, x as the raw camera sees it — i.e. NOT
// mirrored; the UI mirrors for the selfie preview), so nothing downstream needs
// to know which one is running.

import 'package:flutter/widgets.dart';

import 'pose_service_stub.dart'
    if (dart.library.io) 'pose_service_mobile.dart'
    if (dart.library.js_interop) 'pose_service_web.dart' as impl;

/// The body landmarks the games actually use. Both ML Kit and MediaPipe
/// (BlazePose) expose this same topology, so each backend just maps its native
/// landmark ids onto these.
enum PoseJoint {
  nose,
  leftShoulder,
  rightShoulder,
  leftElbow,
  rightElbow,
  leftWrist,
  rightWrist,
  leftHip,
  rightHip,
  leftAnkle,
  rightAnkle,
}

/// One detected body, in normalized upright-frame coordinates (0..1, y down).
class PoseFrame {
  PoseFrame({
    this.leftWrist,
    this.rightWrist,
    this.arms = const [],
    this.points = const {},
  });

  /// Build a frame from a raw joint map, deriving the wrist shortcuts and the
  /// arm/shoulder bones once so both backends stay identical.
  factory PoseFrame.fromPoints(Map<PoseJoint, Offset> pts) {
    final bones = <(Offset, Offset)>[];
    void bone(PoseJoint a, PoseJoint b) {
      final pa = pts[a], pb = pts[b];
      if (pa != null && pb != null) bones.add((pa, pb));
    }

    bone(PoseJoint.leftShoulder, PoseJoint.leftElbow);
    bone(PoseJoint.leftElbow, PoseJoint.leftWrist);
    bone(PoseJoint.rightShoulder, PoseJoint.rightElbow);
    bone(PoseJoint.rightElbow, PoseJoint.rightWrist);
    bone(PoseJoint.leftShoulder, PoseJoint.rightShoulder);

    return PoseFrame(
      leftWrist: pts[PoseJoint.leftWrist],
      rightWrist: pts[PoseJoint.rightWrist],
      arms: bones,
      points: pts,
    );
  }

  final Offset? leftWrist;
  final Offset? rightWrist;
  final List<(Offset, Offset)> arms;

  /// Every detected landmark we care about, normalized 0..1 (y grows downward).
  final Map<PoseJoint, Offset> points;
}

/// Camera + on-device pose estimation. The implementation is platform-specific
/// but the surface is the same everywhere.
abstract class PoseService {
  /// Latest detected frame; widgets can listen for repaints.
  ValueNotifier<PoseFrame> get frame;

  /// Acquire the camera and start streaming poses. Throws on permission /
  /// hardware failure so the UI can show an error.
  Future<void> init();

  /// The live camera preview widget for this platform (native [CameraPreview]
  /// on mobile, an [HtmlElementView] over a `<video>` on web). The caller is
  /// responsible for mirroring/fitting; this returns the raw, unmirrored feed.
  Widget buildPreview(BuildContext context);

  /// Release the camera and detector.
  Future<void> dispose();
}

/// Construct the right backend for the current platform.
PoseService createPoseService() => impl.createPoseService();
