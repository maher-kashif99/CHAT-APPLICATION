plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Google Services plugin for Firebase
    id("com.google.gms.google-services")
}

android {
    namespace = "com.example.chat_application"
    // flutter_webrtc and awesome_notifications both compile against SDK 36.
    compileSdk = 36
    // Must be the highest version any plugin asks for. Flutter's default is
    // 26.3; these plugins all require 27.0.12077973.
    ndkVersion = "27.0.12077973"

    compileOptions {
        // Required by flutter_webrtc and awesome_notifications: they use
        // java.time APIs that need desugaring to run on older Android versions.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.example.chat_application"
        // audio_session (pulled in by just_audio) requires 24; flutter_webrtc needs
        // 23. 24 is the higher of the two and is what the manifest merger wants.
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // ABIs.
        //
        // Ship the two real-phone ABIs. arm64-v8a covers essentially every
        // device made since ~2017; armeabi-v7a is still needed for older and
        // budget hardware, and dropping it makes the app refuse to install
        // there ("app not installed" / INSTALL_FAILED_NO_MATCHING_ABIS).
        //
        // The x86/x86_64 pair is emulator-only and is intentionally excluded —
        // it added 45.7 MB to the original 104.6 MB APK.
        //
        // To install on an x86_64 emulator, temporarily replace this with:
        //   abiFilters += listOf("x86_64")
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
    }

    buildTypes {
        release {
            // TODO: Replace with your own signing config before publishing.
            signingConfig = signingConfigs.getByName("debug")

            // R8 shrinks the Java/Kotlin side. Flutter's Dart code is already
            // tree-shaken at build time, but plugin jars are not. This removes
            // unused classes and shrinks resources.
            //
            // WebRTC's JNI classes must survive — see proguard-rules.pro.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    // Import the Firebase BoM
    implementation(platform("com.google.firebase:firebase-bom:33.5.0"))

    // Add the dependencies for Firebase products you want to use
    // When using the BoM, don't specify versions in Firebase dependencies
    implementation("com.google.firebase:firebase-analytics")
    implementation("com.google.firebase:firebase-messaging")
    implementation("com.google.firebase:firebase-auth")
    implementation("com.google.firebase:firebase-firestore")
    implementation("com.google.firebase:firebase-database")

    // Add the dependencies for any other desired Firebase products
    // https://firebase.google.com/docs/android/setup#available-libraries
}