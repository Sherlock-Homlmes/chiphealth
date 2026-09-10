package vn.chiphealth.app

import io.flutter.embedding.android.FlutterActivity

/**
 * Plain Flutter host. Everything device-side that ChipHealth needs
 * (camera, GPS, mic, notifications, widget bridge) is provided by pub packages,
 * so no MethodChannel is registered here yet.
 *
 * The two foreground services declared in AndroidManifest.xml
 * (`.service.WorkoutRecordingService`, `.service.SleepRecordingService`) are NOT
 * implemented yet — see README § "Sketched".
 */
class MainActivity : FlutterActivity()
