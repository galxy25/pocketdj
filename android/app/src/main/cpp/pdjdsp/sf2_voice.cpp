#define TSF_IMPLEMENTATION
#include "third_party/tsf.h"
#include "sf2_voice.h"

namespace pdj {

Sf2Synth::~Sf2Synth() { if (t_) tsf_close(t_); }

void Sf2Synth::finish(tsf* t, int sampleRate) {
    tsf_set_output(t, TSF_STEREO_INTERLEAVED, sampleRate, 0.0f);
    tsf_set_max_voices(t, 64);  // allocate the voice pool NOW so note_on never allocates on the audio thread
}

bool Sf2Synth::loadFile(const char* path, int sampleRate) {
    tsf* t = tsf_load_filename(path);
    if (!t) return false;
    finish(t, sampleRate);  // configure fully OUTSIDE the lock; swap the pointer under it; free the old one after
    lock(); tsf* old = t_; t_ = t; unlock();
    if (old) tsf_close(old);
    return true;
}

bool Sf2Synth::loadMemory(const void* data, int size, int sampleRate) {
    tsf* t = tsf_load_memory(data, size);
    if (!t) return false;
    finish(t, sampleRate);  // configure fully OUTSIDE the lock; swap the pointer under it; free the old one after
    lock(); tsf* old = t_; t_ = t; unlock();
    if (old) tsf_close(old);
    return true;
}

bool Sf2Synth::setPreset(int bank, int program) {
    lock();
    bool ok = false;
    if (t_) {
        tsf_note_off_all(t_);
        ok = tsf_channel_set_bank_preset(t_, 0, bank, program) != 0 && tsf_get_presetindex(t_, bank, program) >= 0;
    }
    unlock();
    return ok;
}

void Sf2Synth::noteOn(int key, float vel) {
    lock(); if (t_) tsf_channel_note_on(t_, 0, key, vel); unlock();
}
void Sf2Synth::noteOff(int key) {
    lock(); if (t_) tsf_channel_note_off(t_, 0, key); unlock();
}
void Sf2Synth::allOff() {
    lock(); if (t_) tsf_channel_note_off_all(t_, 0); unlock();
}
void Sf2Synth::render(float* out, int frames, bool mix) {
    lock();
    if (t_) tsf_render_float(t_, out, frames, mix ? 1 : 0);
    else if (!mix) for (int i = 0; i < frames * 2; i++) out[i] = 0;
    unlock();
}
int Sf2Synth::presetCount() { lock(); int n = t_ ? tsf_get_presetcount(t_) : 0; unlock(); return n; }
int Sf2Synth::activeVoices() { lock(); int n = t_ ? tsf_active_voice_count(t_) : 0; unlock(); return n; }

}  // namespace pdj
