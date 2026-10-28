#include "stretch.h"
#include "third_party/signalsmith-stretch.h"
#include <vector>
#include <cstring>

namespace pdj {

// Planar adaptors so signalsmith's buffer[channel][index] works on deinterleaved scratch.
bool stretch_exact(const float* in, int inFrames, float* out, int outFrames, int sampleRate, double pitchSemitones) {
    if (inFrames <= 0 || outFrames <= 0) { if (outFrames > 0) std::memset(out, 0, sizeof(float) * 2 * (size_t)outFrames); return false; }
    std::vector<float> inL((size_t)inFrames), inR((size_t)inFrames), outL((size_t)outFrames), outR((size_t)outFrames);
    for (int i = 0; i < inFrames; i++) { inL[i] = in[2 * i]; inR[i] = in[2 * i + 1]; }
    float* inCh[2] = {inL.data(), inR.data()};
    float* outCh[2] = {outL.data(), outR.data()};
    signalsmith::stretch::SignalsmithStretch<float> st;
    st.presetDefault(2, (float)sampleRate);
    st.setTransposeSemitones((float)pitchSemitones);
    bool ok = st.exact(inCh, inFrames, outCh, outFrames);
    if (!ok) { std::memset(out, 0, sizeof(float) * 2 * (size_t)outFrames); return false; }
    for (int i = 0; i < outFrames; i++) { out[2 * i] = outL[i]; out[2 * i + 1] = outR[i]; }
    return true;
}

}  // namespace pdj
