import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

/// One frame of pose data, with landmark positions normalised to 0..1 in the
/// camera image's coordinate space. The screen maps these to pixels (and
/// mirrors them for the front camera).
class PoseFrame {
  PoseFrame({this.leftWrist, this.rightWrist, this.arms = const []});
  final Offset? leftWrist;
  final Offset? rightWrist;
  final List<(Offset, Offset)> arms; // bone segments for the skeleton overlay
}

/// Owns the camera + the ML Kit pose detector and publishes a [PoseFrame]
/// stream via [frame]. Everything runs on-device.
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
    if (_busy) return; // drop frames while one is in flight
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

  /// NOTE: this single-plane conversion works with the nv21 (Android) /
  /// bgra8888 (iOS) formats requested above. Orientation and mirroring are the
  /// most device-specific part of any ML Kit + camera app — verify on a real
  /// device and adjust rotation here if the skeleton looks rotated.
  InputImage? _toInputImage(CameraImage image) {
    final sensorOrientation = _camera!.sensorOrientation;
    final rotation =
        InputImageRotationValue.fromRawValue(sensorOrientation) ??
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
