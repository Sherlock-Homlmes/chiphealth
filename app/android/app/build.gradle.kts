// Config stub. `flutter create .` will regenerate the surrounding Gradle wiring;
// the values that matter to ChipHealth are the applicationId, the SDK levels
// required by the permissions in AndroidManifest.xml, and desugaring (needed by
// flutter_local_notifications).
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// android/key.properties (git-ignored) points at the upload keystore. Google
// Sign-In on Android matches the APK's SHA-1, so debug and release both use
// this one key; without the file the build falls back to the throwaway debug key.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
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
    // KGP 2.2 removed the old kotlinOptions DSL path forward; compilerOptions
    // is the replacement (flutter_foreground_task 11's migration doc).
    kotlin {
        compilerOptions {
            jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
        }
    }

    defaultConfig {
        applicationId = "vn.chiphealth.app"
        // 26 = minimum for Health Connect client + WidgetKit-equivalent APIs we use
        minSdk = 26
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (!keystoreProperties.isEmpty) {
            create("upload") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeType = "pkcs12"
            }
        }
    }

    buildTypes {
        val upload = signingConfigs.findByName("upload")
        debug {
            if (upload != null) signingConfig = upload
        }
        release {
            signingConfig = upload ?: signingConfigs.getByName("debug")
        }
    }
}

flutter { source = "../.." }

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.2")
    implementation("androidx.health.connect:connect-client:1.1.0-alpha07")
}
