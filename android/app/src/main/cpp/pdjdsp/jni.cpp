// Thin JNI surface for com.levi.pocketdj.studio.audio.NativeDsp. Handles are raw pointers in jlong.
// RULE: nothing here is called from the Oboe data callback (that path is pure C++ in oboe_sink.cpp), and
// nothing on the realtime paths allocates: the per-call scratch used below belongs to offline/control calls.
#include <jni.h>
#include <vector>
#include <memory>
#include "fx_kernels.h"
#include "mixer.h"
#include "sf2_voice.h"
#include "stretch.h"
#include "oboe_sink.h"

#define JF(ret, name) extern "C" JNIEXPORT ret JNICALL Java_com_levi_pocketdj_studio_audio_NativeDsp_##name

namespace {
template <class T> T* H(jlong h) { return reinterpret_cast<T*>(h); }

constexpr int kChunk = 512;  // stack scratch block for the FX shims
}  // namespace

// ---- TrackFx -------------------------------------------------------------------------------
JF(jlong, nativeTrackFxNew)(JNIEnv*, jobject, jdouble sr, jint channels) {
    auto* k = new pdj::TrackFx(); k->configure(sr, channels); return reinterpret_cast<jlong>(k);
}
JF(void, nativeTrackFxFree)(JNIEnv*, jobject, jlong h) { delete H<pdj::TrackFx>(h); }
JF(void, nativeTrackFxUpdate)(JNIEnv*, jobject, jlong h, jdouble lo, jdouble mid, jdouble hi, jdouble rev, jdouble dly, jdouble cho, jdouble bpm) {
    pdj::TrackFxParams p; p.eqLowDb = lo; p.eqMidDb = mid; p.eqHighDb = hi; p.reverb = rev; p.delay = dly; p.chorus = cho; p.bpm = bpm > 0 ? bpm : 120;
    H<pdj::TrackFx>(h)->update(p);
}
JF(void, nativeTrackFxReset)(JNIEnv*, jobject, jlong h) { H<pdj::TrackFx>(h)->reset(); }
// interleaved stereo float[] in place
JF(void, nativeTrackFxProcess)(JNIEnv* env, jobject, jlong h, jfloatArray buf, jint frames) {
    if (h == 0 || frames <= 0) return;
    auto* d = static_cast<jfloat*>(env->GetPrimitiveArrayCritical(buf, nullptr));
    if (!d) return;
    float l[kChunk], r[kChunk];  // stack scratch: no malloc on the feeder thread
    for (int off = 0; off < frames; off += kChunk) {
        int n = frames - off < kChunk ? frames - off : kChunk;
        for (int i = 0; i < n; i++) { l[i] = d[2 * (off + i)]; r[i] = d[2 * (off + i) + 1]; }
        float* ch[2] = {l, r};
        H<pdj::TrackFx>(h)->process(ch, 2, n);
        for (int i = 0; i < n; i++) { d[2 * (off + i)] = l[i]; d[2 * (off + i) + 1] = r[i]; }
    }
    env->ReleasePrimitiveArrayCritical(buf, d, 0);
}

// ---- MasterFx ------------------------------------------------------------------------------
JF(jlong, nativeMasterFxNew)(JNIEnv*, jobject, jdouble sr, jint channels) {
    auto* k = new pdj::MasterFx(); k->configure(sr, channels); return reinterpret_cast<jlong>(k);
}
JF(void, nativeMasterFxFree)(JNIEnv*, jobject, jlong h) { delete H<pdj::MasterFx>(h); }
JF(void, nativeMasterFxUpdate)(JNIEnv* env, jobject, jlong h, jdoubleArray a) {
    // layout: [phaser,phaserRate,phaserDepth, ringMod,ringFreq,ringMix, freeze, brazil,brazilAmount, drive,driveAmount, masterGain, bpm]
    jdouble* v = env->GetDoubleArrayElements(a, nullptr);
    pdj::MasterFxParams p;
    p.phaser = v[0] != 0; p.phaserRate = v[1]; p.phaserDepth = v[2];
    p.ringMod = v[3] != 0; p.ringFreq = v[4]; p.ringMix = v[5];
    p.freeze = v[6] != 0; p.brazil = v[7] != 0; p.brazilAmount = v[8];
    p.drive = v[9] != 0; p.driveAmount = v[10]; p.masterGain = v[11]; p.bpm = v[12] > 0 ? v[12] : 120;
    env->ReleaseDoubleArrayElements(a, v, JNI_ABORT);
    H<pdj::MasterFx>(h)->update(p);
}
JF(void, nativeMasterFxProcess)(JNIEnv* env, jobject, jlong h, jfloatArray buf, jint frames, jdouble framePos) {
    if (h == 0 || frames <= 0) return;
    auto* d = static_cast<jfloat*>(env->GetPrimitiveArrayCritical(buf, nullptr));
    if (!d) return;
    float l[kChunk], r[kChunk];
    for (int off = 0; off < frames; off += kChunk) {
        int n = frames - off < kChunk ? frames - off : kChunk;
        for (int i = 0; i < n; i++) { l[i] = d[2 * (off + i)]; r[i] = d[2 * (off + i) + 1]; }
        float* ch[2] = {l, r};
        H<pdj::MasterFx>(h)->process(ch, 2, n, framePos + off);
        for (int i = 0; i < n; i++) { d[2 * (off + i)] = l[i]; d[2 * (off + i) + 1] = r[i]; }
    }
    env->ReleasePrimitiveArrayCritical(buf, d, 0);
}

// ---- Mixer ---------------------------------------------------------------------------------
JF(void, nativeMixAdd)(JNIEnv* env, jobject, jfloatArray dst, jfloatArray src, jint n, jfloat gain) {
    jfloat* d = env->GetFloatArrayElements(dst, nullptr);
    jfloat* s = env->GetFloatArrayElements(src, nullptr);
    pdj::mix_add(d, s, n, gain);
    env->ReleaseFloatArrayElements(src, s, JNI_ABORT);
    env->ReleaseFloatArrayElements(dst, d, 0);
}
JF(void, nativeHardClamp)(JNIEnv* env, jobject, jfloatArray buf, jint n, jfloat limit) {
    jfloat* d = env->GetFloatArrayElements(buf, nullptr);
    pdj::hard_clamp(d, n, limit);
    env->ReleaseFloatArrayElements(buf, d, 0);
}

// ---- SF2 synth -----------------------------------------------------------------------------
JF(jlong, nativeSf2New)(JNIEnv*, jobject) { return reinterpret_cast<jlong>(new pdj::Sf2Synth()); }
JF(void, nativeSf2Free)(JNIEnv*, jobject, jlong h) { delete H<pdj::Sf2Synth>(h); }
JF(jboolean, nativeSf2Load)(JNIEnv* env, jobject, jlong h, jstring path, jint sr) {
    const char* p = env->GetStringUTFChars(path, nullptr);
    if (!p) return JNI_FALSE;
    bool ok = H<pdj::Sf2Synth>(h)->loadFile(p, sr);
    env->ReleaseStringUTFChars(path, p);
    return ok;
}
JF(jboolean, nativeSf2SetPreset)(JNIEnv*, jobject, jlong h, jint bank, jint program) { return H<pdj::Sf2Synth>(h)->setPreset(bank, program); }
JF(void, nativeSf2NoteOn)(JNIEnv*, jobject, jlong h, jint key, jfloat vel) { H<pdj::Sf2Synth>(h)->noteOn(key, vel); }
JF(void, nativeSf2NoteOff)(JNIEnv*, jobject, jlong h, jint key) { H<pdj::Sf2Synth>(h)->noteOff(key); }
JF(void, nativeSf2AllOff)(JNIEnv*, jobject, jlong h) { H<pdj::Sf2Synth>(h)->allOff(); }
JF(void, nativeSf2Render)(JNIEnv* env, jobject, jlong h, jfloatArray out, jint frames, jboolean mix) {
    jfloat* d = env->GetFloatArrayElements(out, nullptr);
    H<pdj::Sf2Synth>(h)->render(d, frames, mix);
    env->ReleaseFloatArrayElements(out, d, 0);
}
JF(jint, nativeSf2PresetCount)(JNIEnv*, jobject, jlong h) { return H<pdj::Sf2Synth>(h)->presetCount(); }

// ---- Stretch -------------------------------------------------------------------------------
JF(jboolean, nativeStretchExact)(JNIEnv* env, jobject, jfloatArray in, jint inFrames, jfloatArray out, jint outFrames, jint sr, jdouble semitones) {
    jfloat* i = env->GetFloatArrayElements(in, nullptr);
    jfloat* o = env->GetFloatArrayElements(out, nullptr);
    bool ok = pdj::stretch_exact(i, inFrames, o, outFrames, sr, semitones);
    env->ReleaseFloatArrayElements(in, i, JNI_ABORT);
    env->ReleaseFloatArrayElements(out, o, 0);
    return ok;
}

// ---- Oboe ----------------------------------------------------------------------------------
JF(jlong, nativeOboeNew)(JNIEnv*, jobject, jint sr, jint ringFrames) { return reinterpret_cast<jlong>(new pdj::OboeOut(sr, ringFrames)); }
JF(void, nativeOboeFree)(JNIEnv*, jobject, jlong h) { delete H<pdj::OboeOut>(h); }
JF(jboolean, nativeOboeOpen)(JNIEnv*, jobject, jlong h) { return H<pdj::OboeOut>(h)->open(); }
JF(void, nativeOboeClose)(JNIEnv*, jobject, jlong h) { H<pdj::OboeOut>(h)->close(); }
JF(jint, nativeOboeWrite)(JNIEnv* env, jobject, jlong h, jfloatArray buf, jint frames) {
    jfloat* d = env->GetFloatArrayElements(buf, nullptr);
    int n = H<pdj::OboeOut>(h)->write(d, frames);
    env->ReleaseFloatArrayElements(buf, d, JNI_ABORT);
    return n;
}
JF(jint, nativeOboeFreeFrames)(JNIEnv*, jobject, jlong h) { return H<pdj::OboeOut>(h)->freeFrames(); }
JF(jint, nativeOboeBuffered)(JNIEnv*, jobject, jlong h) { return H<pdj::OboeOut>(h)->bufferedFrames(); }
JF(jlong, nativeOboeConsumed)(JNIEnv*, jobject, jlong h) { return H<pdj::OboeOut>(h)->consumedFrames(); }
JF(jlong, nativeOboeUnderruns)(JNIEnv*, jobject, jlong h) { return H<pdj::OboeOut>(h)->underruns(); }
JF(jboolean, nativeOboeDisconnected)(JNIEnv*, jobject, jlong h) { return H<pdj::OboeOut>(h)->disconnected(); }
JF(jint, nativeOboeLatency)(JNIEnv*, jobject, jlong h) { return H<pdj::OboeOut>(h)->streamLatencyFrames(); }
