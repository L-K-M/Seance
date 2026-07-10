allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// file_picker ≥11 applies the Kotlin plugin only on AGP <9 and expects AGP 9's
// built-in Kotlin otherwise — but the Flutter template still disables built-in
// Kotlin (android.builtInKotlin=false in gradle.properties). Neither side
// compiles the plugin's Kotlin sources, so the APK build fails with
// "cannot find symbol: FilePickerPlugin" in GeneratedPluginRegistrant.java.
// Re-apply Kotlin for that one subproject (matching the jvmTarget of its javac,
// 17) until Flutter enables built-in Kotlin or file_picker restores the apply:
// https://github.com/miguelpruivo/flutter_file_picker/issues/1973
subprojects {
    if (name == "file_picker") {
        plugins.withId("com.android.library") {
            if (!plugins.hasPlugin("org.jetbrains.kotlin.android")) {
                apply(plugin = "org.jetbrains.kotlin.android")
                val kotlin =
                    extensions.getByName("kotlin")
                        as org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension
                kotlin.compilerOptions.jvmTarget
                    .set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
