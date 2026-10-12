# ProGuard / R8 rules.
#
# Enabled via `isMinifyEnabled = true` in build.gradle.kts. Without these the
# release build compiles but breaks at runtime: plugins reached through JNI or
# reflection are invisible to R8's static analysis, so their classes get
# stripped.
#
# Package names below were verified against the actual plugin sources in
# ~/.pub-cache, not guessed.

# ---------------------------------------------------------------------------
# WebRTC
#
# flutter_webrtc ships its own consumerProguardFiles, so it is covered already
# (its build.gradle declares `consumerProguardFiles 'proguard-rules.pro'`).
# These are repeated here as a belt-and-braces measure, since the native
# library calls back into Java through JNI and no Java-side reference exists.
# Stripping these produces UnsatisfiedLinkError on the first call.
# ---------------------------------------------------------------------------
-keep class com.cloudwebrtc.webrtc.** { *; }
-keep class org.webrtc.** { *; }
-keep class org.jni_zero.** { *; }
-dontwarn org.webrtc.**
-dontwarn com.cloudwebrtc.webrtc.**
-dontwarn org.jni_zero.JniZeroJni

# ---------------------------------------------------------------------------
# record  (package com.llfbandit.record)
#
# Reaches Android's MediaRecorder / AudioRecord reflectively and is loaded via
# the plugin registrant.
# ---------------------------------------------------------------------------
-keep class com.llfbandit.record.** { *; }
-dontwarn com.llfbandit.record.**

# ---------------------------------------------------------------------------
# just_audio + audio_session  (package com.ryanheise.*)
#
# audio_session wraps MediaSessionCompat, which is heavily reflective, and
# just_audio reflects on ExoPlayer / androidx.media3 session classes.
# ---------------------------------------------------------------------------
-keep class com.ryanheise.just_audio.** { *; }
-keep class com.ryanheise.audio_session.** { *; }
-dontwarn com.ryanheise.just_audio.**
-dontwarn com.ryanheise.audio_session.**

-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**

# ---------------------------------------------------------------------------
# Flutter engine + plugin registrant
# ---------------------------------------------------------------------------
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.embedding.** { *; }
-dontwarn io.flutter.embedding.**

# ---------------------------------------------------------------------------
# Supabase / GoTrue
#
# Gotrue deserialises JSON with Gson and stores values on a class hierarchy.
# ---------------------------------------------------------------------------
-keep class io.supabase.** { *; }
-keep class gotrue.** { *; }
-keep class com.gotrue.** { *; }
-dontwarn io.supabase.**
-dontwarn com.gotrue.**
-keep class com.google.gson.** { *; }
-dontwarn com.google.gson.**
-keepclassmembers class * {
    @com.google.gson.annotations.SerializedName <fields>;
}

# ---------------------------------------------------------------------------
# awesome_notifications (package me.carda.aware)
#
# Receivers and services are resolved from AndroidManifest by name; payloads
# round-trip through Gson.
# ---------------------------------------------------------------------------
-keep class me.carda.aware.** { *; }
-keep class com.indeed.** { *; }
-dontwarn me.carda.aware.**
-dontwarn com.indeed.**

# ---------------------------------------------------------------------------
# Kotlin metadata — Supabase and several plugins read it reflectively.
# ---------------------------------------------------------------------------
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod