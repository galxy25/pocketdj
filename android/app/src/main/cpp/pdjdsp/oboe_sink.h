// Oboe output stream fed from a lock-free SPSC float ring. The data callback ONLY copies from the ring
// (or zero-fills on underrun): no JNI, no allocation, no locks. A Kotlin render thread is the producer.
#pragma once
#include <atomic>
#include <memory>
#include <vector>
#include <oboe/Oboe.h>

namespace pdj {

class OboeOut : public oboe::AudioStreamDataCallback, public oboe::AudioStreamErrorCallback {
public:
    OboeOut(int sampleRate, int ringFrames, bool lowLatency = true);
    ~OboeOut();
    bool open();      // build + start the stream
    void close();
    // Producer: non-blocking. Returns frames accepted.
    int write(const float* interleaved, int frames);
    int freeFrames() const;
    int bufferedFrames() const;
    long long consumedFrames() const { return consumed_.load(std::memory_order_acquire); }
    long long underruns() const { return underruns_.load(std::memory_order_relaxed); }
    bool disconnected() const { return disconnected_.load(std::memory_order_acquire); }
    int streamLatencyFrames() const { return latencyFrames_.load(std::memory_order_relaxed); }
    int burstFrames() const { return burst_.load(std::memory_order_relaxed); }

    oboe::DataCallbackResult onAudioReady(oboe::AudioStream*, void* audioData, int32_t numFrames) override;
    void onErrorAfterClose(oboe::AudioStream*, oboe::Result) override;
private:
    int sampleRate_;
    int ringFrames_;
    bool lowLatency_;  // Studio: LowLatency+Exclusive; Mix/Now Playing: PowerSaving+Shared (battery, ducking, coexists with Studio)
    std::vector<float> ring_;
    std::atomic<long long> head_{0};   // frames written (producer)
    std::atomic<long long> tail_{0};   // frames read (consumer = audio callback)
    std::atomic<long long> consumed_{0};
    std::atomic<long long> underruns_{0};
    std::atomic<bool> disconnected_{false};
    std::atomic<int> latencyFrames_{0};
    std::atomic<int> burst_{0};
    std::shared_ptr<oboe::AudioStream> stream_;
};

}  // namespace pdj
