# MoveArcade — Shadow Boxer

A real-time, camera-based fitness boxing game built in Flutter. A pad lights up; you
punch it with your real fist. On-device pose detection (Google ML Kit) reads your wrist
position — **no video ever leaves the phone**. Calories are computed with a deterministic
MET model, never guessed.

This repo is the launch game **plus a reusable engine** that Squat Surfer and Sky Hopper
plug into later — only the input rule (a punch here) changes per game.

## What's here

```
lib/
  main.dart                         app entry
  ui/start_screen.dart              weight input + start
  engine/
    pose_service.dart               camera + ML Kit -> wrist keypoints
    game_engine.dart                loop state, scoring, combo, timer  (shared)
    calorie_engine.dart             MET calorie model                  (shared)
  games/shadow_boxer/
    shadow_boxer_screen.dart        wires it all together
    punch_detector.dart            punch = wrist into lit pad, fast enough
    shadow_boxer_painter.dart       pads, hand markers, skeleton overlay
.github/workflows/flutter-ci.yml   analyze + build APK on every push
```

## Run it (physical device required — camera + pose do not work on a simulator)

```bash
# 1. Generate the platform folders (android/ ios/) for this package
flutter create .

# 2. Get packages
flutter pub get

# 3. Add camera permissions (see "Permissions" below), then run on a plugged-in phone
flutter run
```

### Permissions

**Android** — in `android/app/src/main/AndroidManifest.xml`, inside `<manifest>`:
```xml
<uses-permission android:name="android.permission.CAMERA"/>
```
and set `minSdkVersion 21` (or higher) in `android/app/build.gradle`.

**iOS** — in `ios/Runner/Info.plist`:
```xml
<key>NSCameraUsageDescription</key>
<string>Used to track your movements so you can play.</string>
```

## Push to GitHub

```bash
git init
git add .
git commit -m "Shadow Boxer: real-time pose-based boxing game + shared engine"
git branch -M main
git remote add origin https://github.com/<your-username>/shadow-boxer.git
git push -u origin main
```
CI (`flutter analyze` + debug APK build) runs automatically on push.

## Where the named tools fit

- **GitHub** — this repo + the CI workflow. Version control and automated builds.
- **Claude Code** — open this repo in VS Code with Claude Code and iterate: tuning punch
  sensitivity, fixing the device-specific bits, then adding Squat Surfer / Sky Hopper.
- **Claude Design** — design the screens (start, calibration, HUD, summary) in the Claude
  Design product, then export and wire them in. The visual polish layer.

## Honest notes (this is a working scaffold, not a finished product)

- **Image orientation / mirroring** in `pose_service.dart` is the most device-specific part
  of any ML Kit + camera app. It's set up for nv21 (Android) / bgra8888 (iOS); verify on a
  real device and adjust the rotation if the skeleton looks rotated. This is the first thing
  to do with Claude Code.
- **Plugin versions** in `pubspec.yaml` are recent but may need pinning — run `flutter pub get`
  and let it resolve, or bump to the latest compatible versions.
- **Sensitivity** (punch velocity threshold, MET scaling) is tuned by feel and wants
  calibration on real devices.
- The loop calls `setState` per frame for simplicity; for production move rendering to a
  `RepaintBoundary` / custom render object.
