// ---------------- Mobile pose backend: camera + Google ML Kit ----------------
// Used on Android / iOS. ML Kit runs BlazePose on-device; no video leaves the
// phone. This file is the ONLY place the mobile-only plugins are imported, so
// the web build (which conditionally imports pose_service_web.dart instead)
// never pulls in dart:io, package:camera, or google_mlkit_pose_detection.
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import 'pose_service.dart';

PoseService createPoseService() => MobilePoseService();

/// ML Kit landmark -> the small set of joints the games use.
const _jointMap = <PoseLandmarkType, PoseJoint>{
  PoseLandmarkType.nose: PoseJoint.nose,
  PoseLandmarkType.leftShoulder: PoseJoint.leftShoulder,
  PoseLandmarkType.rightShoulder: PoseJoint.rightShoulder,
  PoseLandmarkType.leftElbow: PoseJoint.leftElbow,
  PoseLandmarkType.rightElbow: PoseJoint.rightElbow,
  PoseLandmarkType.leftWrist: PoseJoint.leftWrist,
  PoseLandmarkType.rightWrist: PoseJoint.rightWrist,
  PoseLandmarkType.leftHip: PoseJoint.leftHip,
  PoseLandmarkType.rightHip: PoseJoint.rightHip,
  PoseLandmarkType.leftAnkle: PoseJoint.leftAnkle,
  PoseLandmarkType.rightAnkle: PoseJoint.rightAnkle,
};

class MobilePoseService implements PoseService {
  CameraController? controller;
  late final PoseDetector _detector;
  CameraDescription? _camera;
  bool _busy = false;

  @override
  final ValueNotifier<PoseFrame> frame = ValueNotifier(PoseFrame());

  // Degrees the camera image must be turned to become upright for each
  // possible device orientation.
  static const _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  @override
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

  @override
  Widget buildPreview(BuildContext context) {
    final c = controller;
    if (c == null || !c.value.isInitialized) return const SizedBox.shrink();
    // Mirror for the selfie preview and cover the available space. previewSize
    // is reported in sensor orientation, so width/height are swapped here.
    return LayoutBuilder(builder: (context, constraints) {
      final preview = c.value.previewSize;
      return Transform.flip(
        flipX: true,
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: preview?.height ?? constraints.maxWidth,
            height: preview?.width ?? constraints.maxHeight,
            child: CameraPreview(c),
          ),
        ),
      );
    });
  }

  Future<void> _process(CameraImage image) async {
    if (_busy) return;
    _busy = true;
    try {
      final rotation = _rotation();
      final input = _toInputImage(image, rotation);
      if (input == null) return;
      final poses = await _detector.processImage(input);
      if (poses.isEmpty) {
        frame.value = PoseFrame();
        return;
      }
      final lm = poses.first.landmarks;
      // ML Kit reports landmarks in the upright (rotated) frame, so for a
      // quarter-turn rotation the image width and height are swapped.
      final quarterTurned = rotation == InputImageRotation.rotation90deg ||
          rotation == InputImageRotation.rotation270deg;
      final w = (quarterTurned ? image.height : image.width).toDouble();
      final h = (quarterTurned ? image.width : image.height).toDouble();
      final pts = <PoseJoint, Offset>{};
      for (final entry in _jointMap.entries) {
        final p = lm[entry.key];
        if (p != null) pts[entry.value] = Offset(p.x / w, p.y / h);
      }
      frame.value = PoseFrame.fromPoints(pts);
    } catch (e) {
      debugPrint('pose error: $e');
    } finally {
      _busy = false;
    }
  }

  // Works out how far ML Kit must rotate the frame to make it upright,
  // combining the camera's fixed sensor mounting angle with the phone's current
  // UI orientation. Front and back cameras combine these in opposite directions
  // because the front sensor image is mirrored.
  InputImageRotation _rotation() {
    final sensor = _camera!.sensorOrientation;
    if (Platform.isIOS) {
      return InputImageRotationValue.fromRawValue(sensor) ??
          InputImageRotation.rotation0deg;
    }
    final deviceRotation =
        _orientations[controller!.value.deviceOrientation] ?? 0;
    final int compensated;
    if (_camera!.lensDirection == CameraLensDirection.front) {
      compensated = (sensor + deviceRotation) % 360;
    } else {
      compensated = (sensor - deviceRotation + 360) % 360;
    }
    return InputImageRotationValue.fromRawValue(compensated) ??
        InputImageRotation.rotation0deg;
  }

  InputImage? _toInputImage(CameraImage image, InputImageRotation rotation) {
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

  @override
  Future<void> dispose() async {
    await controller?.stopImageStream();
    await controller?.dispose();
    await _detector.close();
  }
}
