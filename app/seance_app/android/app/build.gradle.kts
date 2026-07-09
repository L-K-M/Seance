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
        // Séance is a personal, sideloaded app (no Play Store), and its
        // release keystore is committed — password public by design. What
        // that buys: a STABLE identity, so every build (local or CI) can
        // upgrade an existing install in place; the default debug keystore is
        // per-machine/per-CI-run, which forced an uninstall (wiping local
        // data) on every update. What it deliberately gives up: publisher
        // authenticity — anyone can build an APK this key signs, and Android
        // would install it OVER an existing install if the user sideloads it.
        // The trust anchor is therefore the download source (this repo's
        // releases), not the signature. Use a private key instead if that
        // ever stops being acceptable.
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
