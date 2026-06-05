// MediaPipe Tasks Vision pose backend for the Flutter web build.
//
// Google ML Kit is mobile-only, so on the web the Dart side (pose_service_web.dart)
// drives this tiny imperative API instead. Everything heavy — loading the model,
// opening the webcam, and the per-frame detection loop — lives here in JS; Dart
// just calls window.bouncee.* over JS interop and reads landmarks as JSON.
(function () {
  const VERSION = '0.10.14';
  const VISION_URL =
    'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@' + VERSION + '/vision_bundle.mjs';
  const WASM_URL =
    'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@' + VERSION + '/wasm';
  const MODEL_URL =
    'https://storage.googleapis.com/mediapipe-models/pose_landmarker/' +
    'pose_landmarker_lite/float16/1/pose_landmarker_lite.task';

  let landmarker = null;
  let video = null;
  let latest = null; // { present: bool, landmarks: [{x, y, z, visibility}, ...] }
  let running = false;
  let lastTs = -1;

  async function init() {
    // ESM bundle, loaded dynamically so this file can stay a classic script.
    const vision = await import(VISION_URL);
    const { PoseLandmarker, FilesetResolver } = vision;
    const fileset = await FilesetResolver.forVisionTasks(WASM_URL);
    landmarker = await PoseLandmarker.createFromOptions(fileset, {
      baseOptions: { modelAssetPath: MODEL_URL, delegate: 'GPU' },
      runningMode: 'VIDEO',
      numPoses: 1,
    });

    const stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: 'user' },
      audio: false,
    });
    video = document.createElement('video');
    video.autoplay = true;
    video.playsInline = true;
    video.muted = true;
    video.srcObject = stream;
    video.style.width = '100%';
    video.style.height = '100%';
    video.style.objectFit = 'cover';
    video.style.transform = 'scaleX(-1)'; // mirror to match the selfie preview
    await video.play();

    running = true;
    requestAnimationFrame(loop);
    return true;
  }

  function loop() {
    if (!running) return;
    if (landmarker && video && video.readyState >= 2) {
      const ts = performance.now();
      // detectForVideo requires strictly increasing timestamps.
      if (ts > lastTs) {
        lastTs = ts;
        try {
          const res = landmarker.detectForVideo(video, ts);
          if (res && res.landmarks && res.landmarks.length > 0) {
            latest = { present: true, landmarks: res.landmarks[0] };
          } else {
            latest = { present: false, landmarks: [] };
          }
        } catch (e) {
          // Transient frames before the model is warm — skip silently.
        }
      }
    }
    requestAnimationFrame(loop);
  }

  window.bouncee = {
    init: init,
    video: function () {
      return video;
    },
    // Return JSON so Dart gets a plain string and decodes it, avoiding deep
    // JS-object interop.
    latest: function () {
      return latest ? JSON.stringify(latest) : null;
    },
    stop: function () {
      running = false;
      if (video && video.srcObject) {
        video.srcObject.getTracks().forEach(function (t) {
          t.stop();
        });
      }
    },
  };
})();
