// Interleaved-stereo float mixing primitives (the C++ side of RenderGraph / StudioRender.mixPCM).
#pragma once
namespace pdj {
// dst[i] += src[i] * gain for n floats.
void mix_add(float* dst, const float* src, int n, float gain);
// Constant-power-free linear pan: left *= gainL, right *= gainR, accumulated into dst (interleaved stereo frames).
void mix_add_panned(float* dst, const float* src, int frames, float gainL, float gainR);
// Hard clamp to +-limit, in place.
void hard_clamp(float* buf, int n, float limit);
// Peak absolute value.
float peak(const float* buf, int n);
}
