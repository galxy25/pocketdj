#include "fx_kernels.h"
#include <algorithm>

namespace pdj {

static const double kPi = 3.14159265358979323846;

void Biquad::lowShelf(double dB, double f0, double sr, double o[5]) {
    double A = std::pow(10.0, dB / 40), w0 = 2 * kPi * f0 / sr;
    double cw = std::cos(w0), sw = std::sin(w0), alpha = sw / 2 * std::sqrt(2.0), t = 2 * std::sqrt(A) * alpha;
    double a0 = (A + 1) + (A - 1) * cw + t;
    double b0 = A * ((A + 1) - (A - 1) * cw + t);
    double b1 = 2 * A * ((A - 1) - (A + 1) * cw);
    double b2 = A * ((A + 1) - (A - 1) * cw - t);
    double a1 = -2 * ((A - 1) + (A + 1) * cw);
    double a2 = (A + 1) + (A - 1) * cw - t;
    o[0] = b0 / a0; o[1] = b1 / a0; o[2] = b2 / a0; o[3] = a1 / a0; o[4] = a2 / a0;
}

void Biquad::highShelf(double dB, double f0, double sr, double o[5]) {
    double A = std::pow(10.0, dB / 40), w0 = 2 * kPi * f0 / sr;
    double cw = std::cos(w0), sw = std::sin(w0), alpha = sw / 2 * std::sqrt(2.0), t = 2 * std::sqrt(A) * alpha;
    double a0 = (A + 1) - (A - 1) * cw + t;
    double b0 = A * ((A + 1) + (A - 1) * cw + t);
    double b1 = -2 * A * ((A - 1) + (A + 1) * cw);
    double b2 = A * ((A + 1) + (A - 1) * cw - t);
    double a1 = 2 * ((A - 1) - (A + 1) * cw);
    double a2 = (A + 1) - (A - 1) * cw - t;
    o[0] = b0 / a0; o[1] = b1 / a0; o[2] = b2 / a0; o[3] = a1 / a0; o[4] = a2 / a0;
}

void Biquad::peaking(double dB, double f0, double Q, double sr, double o[5]) {
    double A = std::pow(10.0, dB / 40), w0 = 2 * kPi * f0 / sr;
    double cw = std::cos(w0), sw = std::sin(w0), alpha = sw / (2 * Q);
    double a0 = 1 + alpha / A;
    double b0 = 1 + alpha * A;
    double b1 = -2 * cw;
    double b2 = 1 - alpha * A;
    double a1 = -2 * cw;
    double a2 = 1 - alpha / A;
    o[0] = b0 / a0; o[1] = b1 / a0; o[2] = b2 / a0; o[3] = a1 / a0; o[4] = a2 / a0;
}

// ---- TrackFx ------------------------------------------------------------------------------

static const double kChorusBaseMs = 18.0, kChorusDepthMs = 6.0, kChorusRateHz = 0.8;
static const int kCombTunings[4] = {1116, 1188, 1277, 1356};
static const int kAllpassTunings[2] = {556, 441};
static const int kStereoSpread = 23;

void TrackFx::configure(double sampleRate, int channelCount) {
    sr_ = sampleRate > 0 ? sampleRate : 44100;
    channels_ = std::max(1, channelCount);
    double scale = sr_ / 44100.0;
    eq_.assign((size_t)channels_, std::vector<Biquad>(3));
    delayFrames_ = std::max(1, (int)(sr_ * 2));
    delayBuf_.assign((size_t)channels_, std::vector<double>((size_t)std::max(1, (int)(sr_ * 2) + 1), 0.0));
    delayWrite_.assign((size_t)channels_, 0);
    int chorusMax = (int)((kChorusBaseMs + kChorusDepthMs + 2) / 1000 * sr_) + 2;
    chorusBuf_.assign((size_t)channels_, std::vector<double>((size_t)std::max(2, chorusMax), 0.0));
    chorusWrite_.assign((size_t)channels_, 0);
    chorusPhase_.assign((size_t)channels_, 0.0);
    for (int c = 0; c < channels_; c++) chorusPhase_[c] = c * 0.5;
    combs_.clear(); allpasses_.clear();
    for (int c = 0; c < channels_; c++) {
        std::vector<Comb> cs; for (int t : kCombTunings) cs.emplace_back((int)(t * scale) + (c == 1 ? kStereoSpread : 0));
        combs_.push_back(std::move(cs));
        std::vector<AllPass> as; for (int t : kAllpassTunings) as.emplace_back((int)(t * scale) + (c == 1 ? kStereoSpread : 0));
        allpasses_.push_back(std::move(as));
    }
    update(p_);
}

void TrackFx::update(const TrackFxParams& params) {
    p_ = params;
    eqOn_ = std::fabs(params.eqLowDb) > 0.01 || std::fabs(params.eqMidDb) > 0.01 || std::fabs(params.eqHighDb) > 0.01;
    double lo[5], mid[5], hi[5];
    Biquad::lowShelf(params.eqLowDb, 120, sr_, lo);
    Biquad::peaking(params.eqMidDb, 1000, 0.9, sr_, mid);
    Biquad::highShelf(params.eqHighDb, 8000, sr_, hi);
    for (auto& ch : eq_) { ch[0].set(lo); ch[1].set(mid); ch[2].set(hi); }
    double eighth = 60.0 / std::max(20.0, std::min(300.0, params.bpm)) / 2;
    int ringMax = delayBuf_.empty() ? 1 : (int)delayBuf_[0].size() - 1;
    delayFrames_ = std::max(1, std::min(ringMax, (int)(eighth * sr_)));
    delayWet_ = std::max(0.0, std::min(1.0, params.delay));
    chorusWet_ = std::max(0.0, std::min(1.0, params.chorus));
    reverbWet_ = std::max(0.0, std::min(1.0, params.reverb));
    double room = 0.70 + 0.28 * reverbWet_;
    for (auto& cs : combs_) for (auto& k : cs) { k.feedback = room; k.damp1 = 0.2; k.damp2 = 0.8; }
}

void TrackFx::reset() {
    for (auto& ch : eq_) for (auto& b : ch) b.reset();
    for (size_t c = 0; c < delayBuf_.size(); c++) { std::fill(delayBuf_[c].begin(), delayBuf_[c].end(), 0.0); delayWrite_[c] = 0; }
    for (size_t c = 0; c < chorusBuf_.size(); c++) { std::fill(chorusBuf_[c].begin(), chorusBuf_[c].end(), 0.0); chorusWrite_[c] = 0; }
    for (auto& cs : combs_) for (auto& k : cs) k.reset();
    for (auto& as : allpasses_) for (auto& k : as) k.reset();
}

double TrackFx::interp(const std::vector<double>& buf, double pos) const {
    int n = (int)buf.size();
    double p = pos;
    while (p < 0) p += (double)n;
    int i0 = (int)p % n;
    int i1 = (i0 + 1) % n;
    double frac = p - std::floor(p);
    return buf[i0] * (1 - frac) + buf[i1] * frac;
}

void TrackFx::process(float* const* data, int channelCount, int frames) {
    int n = std::min(channelCount, channels_);
    if (n <= 0 || frames <= 0 || (int)eq_.size() < n) return;
    const TrackFxParams params = p_;
    if (!params.active()) return;
    double phaseInc = 2 * kPi * kChorusRateHz / sr_;
    double chorusBase = kChorusBaseMs / 1000 * sr_, chorusDepth = kChorusDepthMs / 1000 * sr_;
    for (int c = 0; c < n; c++) {
        float* d = data[c];
        for (int i = 0; i < frames; i++) {
            double s = (double)d[i];
            if (eqOn_) s = eq_[c][2].process(eq_[c][1].process(eq_[c][0].process(s)));
            if (chorusWet_ > 0) {
                double lfo = (std::sin(chorusPhase_[c]) + 1) / 2;
                double dly = chorusBase + lfo * chorusDepth;
                std::vector<double>& buf = chorusBuf_[c];
                double readPos = (double)chorusWrite_[c] - dly;
                double wet = interp(buf, readPos);
                buf[chorusWrite_[c]] = s;
                if (++chorusWrite_[c] >= (int)buf.size()) chorusWrite_[c] = 0;
                chorusPhase_[c] += phaseInc; if (chorusPhase_[c] > 2 * kPi) chorusPhase_[c] -= 2 * kPi;
                s += wet * chorusWet_ * 0.7;
            }
            if (delayWet_ > 0) {
                int cnt = (int)delayBuf_[c].size();
                int rd = (delayWrite_[c] - delayFrames_ + cnt) % cnt;
                double echo = delayBuf_[c][rd];
                delayBuf_[c][delayWrite_[c]] = s + echo * delayFeedback_;
                if (++delayWrite_[c] >= cnt) delayWrite_[c] = 0;
                s += echo * delayWet_ * 0.8;
            }
            if (reverbWet_ > 0) {
                double input = s * 0.5, acc = 0;
                for (auto& k : combs_[c]) acc += k.process(input);
                acc = allpasses_[c][0].process(acc);
                acc = allpasses_[c][1].process(acc);
                s += acc * reverbWet_ * 0.5;
            }
            d[i] = (float)s;
        }
    }
}

// ---- MasterFx -----------------------------------------------------------------------------

void MasterFx::configure(double sampleRate, int channelCount) {
    sr_ = sampleRate > 0 ? sampleRate : 44100;
    channels_ = std::max(1, channelCount);
    freezeLen_ = std::max(1, (int)(sr_ * 0.25));
    apX_.assign((size_t)channels_, std::vector<double>(kStages, 0.0));
    apY_.assign((size_t)channels_, std::vector<double>(kStages, 0.0));
    freezeBuf_.assign((size_t)channels_, std::vector<float>((size_t)freezeLen_, 0.f));
    freezeWrite_.assign((size_t)channels_, 0);
    freezeRead_.assign((size_t)channels_, 0);
    subLP_.assign((size_t)channels_, 0.0);
    lfoPhase_ = 0; ringPhase_ = 0; wasFrozen_ = false;
}

void MasterFx::process(float* const* data, int channelCount, int frames, double framePos) {
    int n = std::min(channelCount, channels_);
    if (n <= 0 || (int)apX_.size() < n) return;
    const MasterFxParams params = p_;
    if (!params.active()) {
        // keep the freeze ring warm so enabling only the Freezer holds real audio
        for (int i = 0; i < frames; i++)
            for (int c = 0; c < n; c++) {
                freezeBuf_[c][freezeWrite_[c]] = data[c][i];
                freezeWrite_[c] = (freezeWrite_[c] + 1) % freezeLen_;
            }
        wasFrozen_ = false;
        return;
    }
    double lfoInc = 2 * kPi * std::max(0.02, std::min(8.0, params.phaserRate)) / sr_;
    double ringInc = 2 * kPi * std::max(20.0, std::min(4000.0, params.ringFreq)) / sr_;
    double beatFrames = 60.0 / std::max(20.0, std::min(300.0, params.bpm)) * sr_;
    double subCoeff = 1 - std::exp(-2 * kPi * 90.0 / sr_);
    if (params.freeze && !wasFrozen_) for (int c = 0; c < n; c++) freezeRead_[c] = freezeWrite_[c];
    wasFrozen_ = params.freeze;
    for (int i = 0; i < frames; i++) {
        double pos = framePos + (double)i;
        double ringS = params.ringMod ? std::sin(ringPhase_) : 0;
        double phaserA = 0;
        if (params.phaser) {
            double lfo = std::sin(lfoPhase_);
            double f = 200.0 * std::pow(10.0, (lfo + 1) / 2);
            double t = std::tan(kPi * std::min(0.49, f / sr_));
            phaserA = (t - 1) / (t + 1);
        }
        double beatEnv = 0;
        if (params.brazil) {
            double ph = std::fmod(pos, beatFrames) / beatFrames;
            if (ph < 0) ph += 1;
            beatEnv = (1 - ph); beatEnv *= beatEnv;
        }
        for (int c = 0; c < n; c++) {
            double x = (double)data[c][i];
            if (params.phaser) {
                double s = x;
                for (int st = 0; st < kStages; st++) {
                    double y = phaserA * s + apX_[c][st] - phaserA * apY_[c][st];
                    apX_[c][st] = s; apY_[c][st] = y; s = y;
                }
                double wet = 0.5 * (x + s);
                x = x * (1 - params.phaserDepth) + wet * params.phaserDepth;
            }
            if (params.ringMod) x = x * (1 - params.ringMix) + (x * ringS) * params.ringMix;
            if (params.freeze) {
                x = (double)freezeBuf_[c][freezeRead_[c]];
                freezeRead_[c] = (freezeRead_[c] + 1) % freezeLen_;
            } else {
                freezeBuf_[c][freezeWrite_[c]] = (float)x;
                freezeWrite_[c] = (freezeWrite_[c] + 1) % freezeLen_;
            }
            if (params.brazil) {
                subLP_[c] += subCoeff * (x - subLP_[c]);
                x += params.brazilAmount * beatEnv * subLP_[c] * 1.6;
            }
            if (params.drive) {
                double g = 1.0 + params.driveAmount * 9.0;
                x = std::tanh(x * g) / (1.0 + params.driveAmount * 1.5);
            }
            x *= params.masterGain;
            data[c][i] = (float)std::max(-1.8, std::min(1.8, x));
        }
        if (params.phaser) { lfoPhase_ += lfoInc; if (lfoPhase_ > 2 * kPi) lfoPhase_ -= 2 * kPi; }
        if (params.ringMod) { ringPhase_ += ringInc; if (ringPhase_ > 2 * kPi) ringPhase_ -= 2 * kPi; }
    }
}

}  // namespace pdj
