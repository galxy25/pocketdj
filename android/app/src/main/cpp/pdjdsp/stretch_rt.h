// REAL-TIME time/pitch (Signalsmith Stretch) for the Mix / Now Playing decks.
// Control-thread: construct / destroy. Render-thread: setPitch / process / reset (no allocation, no locks).
#pragma once
#include <memory>
#include <vector>

namespace pdj {

class RtStretch {
public:
    // maxIn / maxOut bound one process() call (scratch is allocated once, here).
    RtStretch(int sampleRate, int maxIn, int maxOut);
    ~RtStretch();
    RtStretch(const RtStretch&) = delete;
    RtStretch& operator=(const RtStretch&) = delete;

    void setPitchSemitones(double semitones);
    // Consume inFrames of interleaved stereo and emit EXACTLY outFrames (playback rate = inFrames/outFrames,
    // changeable per call). Oversized requests are clamped to the scratch and the remainder zero-filled.
    void process(const float* in, int inFrames, float* out, int outFrames);
    void reset();
    int inputLatency() const { return inLat_; }
    int outputLatency() const { return outLat_; }

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
    int maxIn_, maxOut_;
    int inLat_ = 0, outLat_ = 0;
    std::vector<float> inL_, inR_, outL_, outR_;
};

}  // namespace pdj
