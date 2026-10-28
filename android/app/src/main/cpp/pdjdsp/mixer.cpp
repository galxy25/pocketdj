#include "mixer.h"
#include <algorithm>
#include <cmath>
namespace pdj {
void mix_add(float* dst, const float* src, int n, float gain) {
    for (int i = 0; i < n; i++) dst[i] += src[i] * gain;
}
void mix_add_panned(float* dst, const float* src, int frames, float gainL, float gainR) {
    for (int i = 0; i < frames; i++) {
        dst[2 * i] += src[2 * i] * gainL;
        dst[2 * i + 1] += src[2 * i + 1] * gainR;
    }
}
void hard_clamp(float* buf, int n, float limit) {
    for (int i = 0; i < n; i++) buf[i] = std::max(-limit, std::min(limit, buf[i]));
}
float peak(const float* buf, int n) {
    float p = 0;
    for (int i = 0; i < n; i++) p = std::max(p, std::fabs(buf[i]));
    return p;
}
}  // namespace pdj
