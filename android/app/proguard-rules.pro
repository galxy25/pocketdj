# PocketDJ release R8 rules (release plan A1.5).
#
# Shrink AND obfuscate (Play "DEX code optimization": v1 shipped -dontobfuscate and scored 6%
# obfuscation; Play wants >= 25%). Crash/diag stack traces are de-obfuscated with the
# mapping.txt that release-aab.sh saves next to every AAB (and Play keeps per upload) — use
# `retrace` from cmdline-tools on NPLog/diag traces. Class names that are PERSISTED or looked up
# by name are kept below (WorkManager workers, Glance callbacks, JNI, Apple/JavaCPP, serializers);
# everything else may be renamed. `javaClass.simpleName` is only used in log strings.
-keepattributes SourceFile,LineNumberTable,Signature,InnerClasses,EnclosingMethod,*Annotation*
-renamesourcefileattribute SourceFile

# --- Apple Music for Android SDK (vendored AARs) --------------------------------------------
# mediaplayback is JavaCPP-backed: libappleMusicSDK.so calls back into Java by name, and its
# consumer proguard.txt only covers part of that surface. musickitauth ships NO consumer rules.
# Keep both SDKs whole; they are a small fraction of the dex.
-keep class com.apple.android.** { *; }
-keep interface com.apple.android.** { *; }
-keep class org.bytedeco.javacpp.** { *; }
-dontwarn com.apple.android.**
-dontwarn org.bytedeco.**

# --- JNI: Studio native DSP (cpp/pdjdsp/jni.cpp exports Java_com_levi_pocketdj_studio_audio_NativeDsp_*)
-keep class com.levi.pocketdj.studio.audio.NativeDsp { *; }
-keepclasseswithmembernames,includedescriptorclasses class * { native <methods>; }

# --- kotlinx.serialization ------------------------------------------------------------------
-keepclassmembers @kotlinx.serialization.Serializable class ** {
    static ** Companion;
    *** Companion;
    kotlinx.serialization.KSerializer serializer(...);
}
-keepclassmembers class **$$serializer { *; }
-keepclasseswithmembers class ** { kotlinx.serialization.KSerializer serializer(...); }
-keep,includedescriptorclasses class com.levi.pocketdj.**$$serializer { *; }
# (A blanket "keep every app class's Companion" rule used to live here. Only @Serializable classes
# need it -- covered above and by kotlinx-serialization's own consumer rules -- and nothing in the app
# reflects on companions, so it only blocked R8 from inlining/merging ~all companion objects.)
-dontnote kotlinx.serialization.**

# --- Enums persisted / parsed by name (valueOf / entries) -----------------------------------
# Enum.name()/valueOf() use the constructor's string literal, so obfuscating the constant fields is
# safe; these members are what Enum.valueOf(Class, String) / getEnumConstants() reach reflectively.
-keepclassmembers enum com.levi.pocketdj.** {
    public static **[] values();
    public static ** valueOf(java.lang.String);
    **[] $VALUES;
}

# --- Glance: action callbacks are instantiated reflectively from their class name, which is
# written into widget PendingIntents (they survive an app update until the widget re-renders).
-keep class * implements androidx.glance.appwidget.action.ActionCallback { <init>(); }
# GlanceAppWidgetManager persists each provider's canonicalName in its DataStore and
# getGlanceIds(NowPlayingWidget::class.java) looks it up by that name: a renamed provider finds no
# widgets (refreshWidgets silently no-ops) until the next APPWIDGET_UPDATE re-registers it.
-keepnames class * extends androidx.glance.appwidget.GlanceAppWidget

# --- WorkManager: workers are created reflectively from the class name PERSISTED in WorkManager's
# database (periodic work enqueued by 1.0.0 must still resolve after an update), so the names of
# every worker stay stable across builds.
-keep class * extends androidx.work.ListenableWorker {
    public <init>(android.content.Context, androidx.work.WorkerParameters);
}
# WorkManager's Room database is created reflectively (Room.databaseBuilder ->
# WorkDatabase_Impl.<init>()). room-runtime 2.6.1's consumer rule keeps only the CLASS
# ("-keep class * extends RoomDatabase"); the R8 shipped with AGP 9 removes the unused-looking
# no-arg constructor under full mode, and the app crashed in androidx.startup on every launch
# (NoSuchMethodException: WorkDatabase_Impl.<init> [], caught by the 2026-11 AGP 9 smoke test).
-keep class * extends androidx.room.RoomDatabase { <init>(); }

# --- Media3 / MediaSession / Android Auto: manifest-declared services are kept by aapt rules;
# keep session callback surfaces that Media3 reaches through binder reflection.
-keep class com.levi.pocketdj.playback.PlaybackService { *; }

# --- Tink (androidx.security.crypto) / OkHttp / misc compile-only annotations ----------------
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
-dontwarn com.google.api.client.**
-dontwarn org.joda.time.**

# --- ShazamKit (vendored AAR) -> Retrofit 2.9 + Gson ----------------------------------------
# The AAR's consumer rules keep only com.shazam.shazamkit.internal.** (+ MediaItem members), while
# its Gson/Retrofit internals also touch the public API package (DeveloperToken, Signature,
# MatchResult, MatchedMediaItem...). With obfuscation on, R8 would rename/inline those; a real
# match can't be produced on the emulator to prove they're safe, so keep the whole (small) SDK.
-keep class com.shazam.shazamkit.** { *; }
-keep interface com.shazam.shazamkit.** { *; }
# ShazamKit's RecognitionEndpoint is a Retrofit `suspend` interface. Retrofit 2.9's embedded rules
# predate R8 full mode (AGP 8 default), which strips generic signatures from classes that are not
# kept; Retrofit then cannot read the Continuation/Call/Response type arguments at runtime. These
# are the rules Retrofit 2.10+ ships.
-keep,allowobfuscation,allowshrinking interface retrofit2.Call
-keep,allowobfuscation,allowshrinking class retrofit2.Response
-keep,allowobfuscation,allowshrinking class kotlin.coroutines.Continuation
-dontwarn retrofit2.**
