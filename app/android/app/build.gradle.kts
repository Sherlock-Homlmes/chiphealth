// Config stub. `flutter create .` will regenerate the surrounding Gradle wiring;
// the values that matter to ChipHealth are the applicationId, the SDK levels
// required by the permissions in AndroidManifest.xml, and desugaring (needed by
// flutter_local_notifications).
plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "vn.chiphealth.app"
    // 36 because androidx.activity 1.13 (transitive via the newer plugins)
    // refuses to compile against anything older; targetSdk stays 35.
    compileSdk = 36
    // No ndkVersion: nothing in the app or its plugins compiles native code
    // (tflite_flutter is pure Kotlin and ships .so via Maven), and pinning
    // flutter.ndkVersion forces every build machine to pre-install a ~2.5 GB
    // NDK it never invokes.

    compileOptions {
        // flutter_local_notifications >= 17 needs core library desugaring
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    defaultConfig {
        applicationId = "vn.chiphealth.app"
        // 26 = minimum for Health Connect client + WidgetKit-equivalent APIs we use
        minSdk = 26
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: replace with a real signing config before shipping.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter { source = "../.." }

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.2")
    implementation("androidx.health.connect:connect-client:1.1.0-alpha07")
}
