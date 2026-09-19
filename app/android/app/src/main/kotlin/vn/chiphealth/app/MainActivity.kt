package vn.chiphealth.app

import io.flutter.embedding.android.FlutterActivity

/**
 * Plain Flutter host. Everything device-side that ChipHealth needs
 * (camera, GPS, mic, notifications, widget bridge) is provided by pub packages,
 * so no MethodChannel is registered here yet.
 *
 * The sleep recorder's foreground service is flutter_foreground_task's
 * (declared in AndroidManifest.xml, started from Dart with the microphone
 * type). `.service.WorkoutRecordingService` is still NOT implemented —
 * see README § "Sketched".
 */
class MainActivity : FlutterActivity()
