pluginManagement {
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        val flutterSdkPath = properties.getProperty("flutter.sdk")
        require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
        flutterSdkPath
    }
    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // 8.9.1: androidx.activity 1.13 (pulled in transitively by the newer
    // plugins) refuses to build under older AGP.
    id("com.android.application") version "8.9.1" apply false
    // 2.2.20: flutter_foreground_task 11.x is compiled against Kotlin 2.x
    // metadata; the 1.9 compiler cannot consume it.
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

include(":app")
