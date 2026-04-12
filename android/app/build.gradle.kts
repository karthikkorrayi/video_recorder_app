import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreFile = rootProject.file("key.properties")
val keystoreProps = Properties()
if (keystoreFile.exists()) {
    keystoreProps.load(FileInputStream(keystoreFile))
}

configurations.all {
    resolutionStrategy.eachDependency {
        if (requested.group == "com.arthenica") {
            if (requested.name.startsWith("ffmpeg-kit-full")) {
                // Swap full-gpl for min — same version, smaller package
                useTarget("com.arthenica:ffmpeg-kit-min:${requested.version}")
                because("OTN only needs H.264/AAC — min variant saves ~68MB")
            }
        }
    }
}

android {
    namespace = "com.example.video_recorder_app"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = "11"
    }

    defaultConfig {
        applicationId = "com.otn.videorecorder"
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // splits {
    //     abi {
    //         isEnable = true
    //         reset()
    //         include("arm64-v8a", "armeabi-v7a", "x86_64")
    //         isUniversalApk = false
    //     }
    // }

    signingConfigs {
        if (keystoreFile.exists()) {
            create("release") {
                keyAlias      = keystoreProps["keyAlias"] as String
                keyPassword   = keystoreProps["keyPassword"] as String
                storeFile     = file(keystoreProps["storeFile"] as String)
                storePassword = keystoreProps["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystoreFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")

            isMinifyEnabled   = false
            isShrinkResources = false
        }
        debug {
            isMinifyEnabled   = false
            isShrinkResources = false
        }
    }

    packaging {
        resources {
            excludes += listOf(
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE",
                "META-INF/LICENSE.txt",
                "META-INF/NOTICE",
                "META-INF/NOTICE.txt",
                "/META-INF/{AL2.0,LGPL2.1}",
            )
        }
        jniLibs {
            pickFirsts += listOf("lib/**/libc++_shared.so")
        }
    }
}

flutter { source = "../.." }

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
    implementation("org.jetbrains.kotlin:kotlin-stdlib-jdk8:1.9.25")
}