// OFFLINE time/pitch (Signalsmith Stretch). Never called from an audio callback.
#pragma once
namespace pdj {
// in: interleaved stereo (inFrames). out: interleaved stereo buffer of EXACTLY outFrames.
// Returns false (out zeroed) when the input is too short for the exact-mode seek; the caller falls back.
bool stretch_exact(const float* in, int inFrames, float* out, int outFrames, int sampleRate, double pitchSemitones);
}
