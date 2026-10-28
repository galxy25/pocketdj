// TinySoundFont wrapper: ONE preset per synth (the iOS "loadSoundBankInstrument loads one preset" fact).
// note/render calls are serialized by a tiny spinlock (MIDI thread vs audio thread); render never allocates
// because max voices are pre-sized at load.
#pragma once
#include <atomic>
#include <string>

struct tsf;

namespace pdj {
class Sf2Synth {
public:
    ~Sf2Synth();
    bool loadFile(const char* path, int sampleRate);
    bool loadMemory(const void* data, int size, int sampleRate);
    // Select GM program (and bank) on channel 0. Returns false when the preset doesn't exist.
    bool setPreset(int bank, int program);
    void noteOn(int key, float velocity01);
    void noteOff(int key);
    void allOff();
    // Adds (mix=true) or writes interleaved stereo float.
    void render(float* interleaved, int frames, bool mix);
    int presetCount();
    int activeVoices();
private:
    void lock() { while (flag_.test_and_set(std::memory_order_acquire)) {} }
    void unlock() { flag_.clear(std::memory_order_release); }
    void finish(int sampleRate);
    tsf* t_ = nullptr;
    std::atomic_flag flag_ = ATOMIC_FLAG_INIT;
};
}
