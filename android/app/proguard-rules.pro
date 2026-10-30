# Add project specific ProGuard rules here.
# Placeholder — minification is disabled for now (Phase 1 skeleton).

# ShazamKit 2.1.1 (mirrors the AAR's consumer rules)
-keepattributes Signature
-keep class com.shazam.sigx.** { *; }
-keep class com.shazam.jni.** { *; }
-keep class com.shazam.sig.** { *; }
-keep class com.shazam.recognition.** { *; }
-keep class com.shazam.shazamkit.internal.** { *; }
-keepclassmembers class com.shazam.shazamkit.MediaItem { *; }
