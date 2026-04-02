# android/app/proguard-rules.pro

# Flutter engine
-keep class io.flutter.** { *; }
-keep class io.flutter.embedding.** { *; }
-dontwarn io.flutter.**

# video_compress (replaces ffmpeg)
-keep class com.ruizuikees.videocompress.** { *; }
-dontwarn com.ruizuikees.videocompress.**

# Firebase
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.firebase.**
-dontwarn com.google.android.gms.**

# ML Kit / TFLite
-keep class com.google.mlkit.** { *; }
-keep class org.tensorflow.** { *; }
-dontwarn com.google.mlkit.**
-dontwarn org.tensorflow.**

# Camera
-keep class io.flutter.plugins.camera.** { *; }
-dontwarn io.flutter.plugins.camera.**

# Video Player
-keep class io.flutter.plugins.videoplayer.** { *; }

# Kotlin
-keep class kotlin.** { *; }
-keep class kotlin.Metadata { *; }
-dontwarn kotlin.**

# Native methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# Enums
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# Suppress common warnings
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
-dontwarn javax.annotation.**