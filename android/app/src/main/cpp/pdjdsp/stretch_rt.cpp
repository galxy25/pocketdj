#include "stretch_rt.h"
#include "third_party/signalsmith-stretch.h"
#include <cstring>

namespace pdj {

struct RtStretch::Impl {
    signalsmith::stretch::SignalsmithStretch<float> st;
};

RtStretch::RtStretch(int sampleRate, int maxIn, int maxOut)
    : impl_(new Impl()), maxIn_(maxIn), maxOut_(maxOut),
      inL_((size_t)maxIn), inR_((size_t)maxIn), outL_((size_t)maxOut), outR_((size_t)maxOut) {
    // splitComputation spreads the STFT work over the block so one render callback never takes a spike.
    impl_->st.presetDefault(2, (float)sampleRate, true);
    inLat_ = impl_->st.inputLatency();
    outLat_ = impl_->st.outputLatency();
}

RtStretch::~RtStretch() = default;

void RtStretch::setPitchSemitones(double semitones) {
    impl_->st.setTransposeSemitones((float)semitones);
}

void RtStretch::reset() { impl_->st.reset(); }

void RtStretch::process(const float* in, int inFrames, float* out, int outFrames) {
    if (outFrames <= 0) return;
    int nIn = inFrames < maxIn_ ? inFrames : maxIn_;
    int nOut = outFrames < maxOut_ ? outFrames : maxOut_;
    if (nIn < 0) nIn = 0;
    for (int i = 0; i < nIn; i++) { inL_[i] = in[2 * i]; inR_[i] = in[2 * i + 1]; }
    float* inCh[2] = {inL_.data(), inR_.data()};
    float* outCh[2] = {outL_.data(), outR_.data()};
    impl_->st.process(inCh, nIn, outCh, nOut);
    for (int i = 0; i < nOut; i++) { out[2 * i] = outL_[i]; out[2 * i + 1] = outR_[i]; }
    if (nOut < outFrames) std::memset(out + 2 * nOut, 0, sizeof(float) * 2 * (size_t)(outFrames - nOut));
}

}  // namespace pdj
