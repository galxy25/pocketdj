// TrackFX / MasterFX DSP kernels: line-for-line ports of Studio/TrackFX.swift and MasterFX.swift.
// Pure C++17 (no Android headers) so the same file compiles on a host for golden-vector checks.
// All state is allocated in configure(); process() never allocates.
#pragma once
#include <cmath>
#include <vector>

namespace pdj {

struct TrackFxParams {
    double eqLowDb = 0, eqMidDb = 0, eqHighDb = 0;
    double reverb = 0, delay = 0, chorus = 0;
    double bpm = 120;
    bool active() const {
        return std::fabs(eqLowDb) > 0.01 || std::fabs(eqMidDb) > 0.01 || std::fabs(eqHighDb) > 0.01 ||
               reverb > 0.001 || delay > 0.001 || chorus > 0.001;
    }
};

struct Biquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
    void reset() { x1 = x2 = y1 = y2 = 0; }
    inline double process(double x) {
        double y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
        x2 = x1; x1 = x; y2 = y1; y1 = y;
        return y;
    }
    // Normalized (by a0) coefficients: {b0,b1,b2,a1,a2}
    static void lowShelf(double dB, double f0, double sr, double out[5]);
    static void highShelf(double dB, double f0, double sr, double out[5]);
    static void peaking(double dB, double f0, double Q, double sr, double out[5]);
    void set(const double c[5]) { b0 = c[0]; b1 = c[1]; b2 = c[2]; a1 = c[3]; a2 = c[4]; }
};

struct Comb {
    std::vector<double> buf; int idx = 0; double store = 0, feedback = 0, damp1 = 0, damp2 = 0;
    explicit Comb(int size = 1) : buf((size_t)(size > 1 ? size : 1), 0.0) {}
    void reset() { std::fill(buf.begin(), buf.end(), 0.0); store = 0; }
    inline double process(double x) {
        double y = buf[idx];
        store = y * damp2 + store * damp1;
        buf[idx] = x + store * feedback;
        if (++idx >= (int)buf.size()) idx = 0;
        return y;
    }
};

struct AllPass {
    std::vector<double> buf; int idx = 0; double feedback = 0.5;
    explicit AllPass(int size = 1) : buf((size_t)(size > 1 ? size : 1), 0.0) {}
    void reset() { std::fill(buf.begin(), buf.end(), 0.0); }
    inline double process(double x) {
        double bufout = buf[idx];
        double y = -x + bufout;
        buf[idx] = x + bufout * feedback;
        if (++idx >= (int)buf.size()) idx = 0;
        return y;
    }
};

class TrackFx {
public:
    void configure(double sampleRate, int channelCount);
    void update(const TrackFxParams& params);
    void reset();
    bool active() const { return p_.active(); }
    // data[c] = channel c, `frames` samples, processed in place.
    void process(float* const* data, int channelCount, int frames);
private:
    double interp(const std::vector<double>& buf, double pos) const;
    double sr_ = 44100; int channels_ = 2; TrackFxParams p_;
    std::vector<std::vector<Biquad>> eq_; bool eqOn_ = false;
    std::vector<std::vector<double>> delayBuf_; std::vector<int> delayWrite_;
    int delayFrames_ = 1; double delayFeedback_ = 0.34, delayWet_ = 0;
    std::vector<std::vector<double>> chorusBuf_; std::vector<int> chorusWrite_; std::vector<double> chorusPhase_;
    double chorusWet_ = 0;
    std::vector<std::vector<Comb>> combs_; std::vector<std::vector<AllPass>> allpasses_;
    double reverbWet_ = 0;
};

struct MasterFxParams {
    bool phaser = false; double phaserRate = 0.5, phaserDepth = 0.6;
    bool ringMod = false; double ringFreq = 200, ringMix = 0.5;
    bool freeze = false;
    bool brazil = false; double brazilAmount = 0.6;
    bool drive = false; double driveAmount = 0.5;
    double masterGain = 1.0;
    double bpm = 120;
    bool active() const { return phaser || ringMod || freeze || brazil || drive || std::fabs(masterGain - 1) > 0.001; }
};

class MasterFx {
public:
    void configure(double sampleRate, int channelCount);
    void update(const MasterFxParams& params) { p_ = params; }
    void process(float* const* data, int channelCount, int frames, double framePos);
private:
    double sr_ = 44100; int channels_ = 2; MasterFxParams p_;
    static constexpr int kStages = 4;
    double lfoPhase_ = 0, ringPhase_ = 0;
    std::vector<std::vector<double>> apX_, apY_;
    std::vector<std::vector<float>> freezeBuf_;
    std::vector<int> freezeWrite_, freezeRead_;
    int freezeLen_ = 1; bool wasFrozen_ = false;
    std::vector<double> subLP_;
};

}  // namespace pdj
