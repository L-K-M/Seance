plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.lkm.seance_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.lkm.seance_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // Séance is a personal, sideloaded app (no Play Store), so its release
        // signature intentionally carries debug-grade trust — but it must be
        // STABLE: Android only installs an update over an existing app when
        // the signatures match, and the default debug keystore is generated
        // per machine (and per CI run), which would force an uninstall (and
        // wipe local data) on every upgrade. The keystore is committed and its
        // password is public by design; it secures nothing and exists only to
        // give every build, local or CI, the same identity.
        create("release") {
            storeFile = file("ci-release.jks")
            storePassword = "seance-release"
            keyAlias = "seance"
            keyPassword = "seance-release"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
