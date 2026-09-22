plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.meowni.meowni"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        // Required to declare app_name via resValue per build type.
        resValues = true
        // Generates BuildConfig (used to gate the debug SMS injector).
        buildConfig = true
    }

    compileOptions {
        // Required by flutter_local_notifications for java.time on older APIs.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.meowni.meowni"
        // flutter_secure_storage and flutter_contacts require API 24+.
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Default launcher name for release/profile; debug overrides it below.
        // Referenced by the manifest as @string/app_name.
        resValue("string", "app_name", "Meowni")
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
        debug {
            // Install alongside the release app as a separate, isolated package
            // (own data/PIN/cache) so debugging never touches the real install.
            applicationIdSuffix = ".debug"
            resValue("string", "app_name", "Meowni Debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
