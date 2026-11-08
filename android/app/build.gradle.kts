import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseProperties = Properties()
val releasePropertiesFile = rootProject.file("key.properties")
if (releasePropertiesFile.exists()) releaseProperties.load(releasePropertiesFile.inputStream())

android {
    namespace = "pl.silique.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        // Stable installed identity: changing it would create a separate app and lose access to existing data.
        applicationId = "pl.novanotes.nova_notes"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
        unitTests.all {
            it.maxHeapSize = "512m"
            it.maxParallelForks = 1
        }
    }

    signingConfigs {
        if (releasePropertiesFile.exists()) {
            create("release") {
                keyAlias = releaseProperties.getProperty("keyAlias")
                keyPassword = releaseProperties.getProperty("keyPassword")
                storeFile = file(releaseProperties.getProperty("storeFile"))
                storePassword = releaseProperties.getProperty("storePassword")
            }
        }
    }
    testOptions {
        unitTests.isIncludeAndroidResources = true
    }

    buildTypes {
        release {
            if (releasePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

// Debug builds must work on a fresh clone without the owner's signing key.
// Release builds always fail before packaging when signing is not configured.
val validateSiliqueReleaseSigning = tasks.register("validateSiliqueReleaseSigning") {
    doLast {
        if (!releasePropertiesFile.exists()) {
            throw GradleException("Release signing requires android/key.properties. See docs/releases.md")
        }
    }
}
tasks.configureEach {
    if (name == "preReleaseBuild") dependsOn(validateSiliqueReleaseSigning)
    // AGP 9 host tests package Flutter's copied assets as well as Android assets.
    if (name == "packageDebugUnitTestForUnitTest") dependsOn("copyFlutterAssetsDebug")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16.1")
    testImplementation("androidx.test:core:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
}

flutter {
    source = "../.."
}
