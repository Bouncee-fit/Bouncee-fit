// Fallback backend for platforms that are neither dart:io nor web. This is
// never selected on Android/iOS or in the browser; it exists so the conditional
// import in pose_service.dart always resolves.
import 'pose_service.dart';

PoseService createPoseService() =>
    throw UnsupportedError('No pose backend for this platform.');
