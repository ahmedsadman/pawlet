import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is driven by android/key.properties (git-ignored; written from CI
// secrets or created locally). Absent that file we fall back to the debug key below, so
// `flutter run --release` still works without a keystore.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.pastabyte.pawlet"
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
        applicationId = "com.pastabyte.pawlet"
        // flutter_secure_storage and flutter_contacts require API 24+.
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Default launcher name for release/profile; debug overrides it below.
        // Referenced by the manifest as @string/app_name.
        resValue("string", "app_name", "Pawlet")
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Sign with the release key when android/key.properties is present (CI or a
            // configured local build); otherwise fall back to the debug key so
            // `flutter run --release` still works without a keystore.
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
        debug {
            // Install alongside the release app as a separate, isolated package
            // (own data/PIN/cache) so debugging never touches the real install.
            applicationIdSuffix = ".debug"
            resValue("string", "app_name", "Pawlet Debug")
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
    implementation("com.google.android.play:integrity:1.4.0")
}

flutter {
    source = "../.."
}
