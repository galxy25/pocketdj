#include "oboe_sink.h"
#include <algorithm>
#include <cstring>

namespace pdj {

OboeOut::OboeOut(int sampleRate, int ringFrames, bool lowLatency)
    : sampleRate_(sampleRate), ringFrames_(ringFrames), lowLatency_(lowLatency), ring_((size_t)ringFrames * 2, 0.f) {}

OboeOut::~OboeOut() { close(); }

bool OboeOut::open() {
    close();
    // Stream is closed => no callback is running, so dropping stale audio here is race-free (re-prime on rebuild).
    tail_.store(head_.load(std::memory_order_acquire), std::memory_order_release);
    disconnected_.store(false, std::memory_order_release);
    oboe::AudioStreamBuilder b;
    b.setDirection(oboe::Direction::Output)
        ->setPerformanceMode(lowLatency_ ? oboe::PerformanceMode::LowLatency : oboe::PerformanceMode::PowerSaving)
        ->setSharingMode(lowLatency_ ? oboe::SharingMode::Exclusive : oboe::SharingMode::Shared)
        ->setFormat(oboe::AudioFormat::Float)
        ->setChannelCount(2)
        ->setSampleRate(sampleRate_)
        ->setSampleRateConversionQuality(oboe::SampleRateConversionQuality::Medium)
        ->setUsage(oboe::Usage::Media)
        ->setContentType(oboe::ContentType::Music)
        ->setDataCallback(this)
        ->setErrorCallback(this);
    oboe::Result r = b.openStream(stream_);
    if (r != oboe::Result::OK || !stream_) { stream_.reset(); return false; }
    int burst = stream_->getFramesPerBurst();
    burst_.store(burst, std::memory_order_relaxed);
    stream_->setBufferSizeInFrames(burst * (lowLatency_ ? 2 : 4));  // two bursts: low latency without crackle
    latencyFrames_.store(stream_->getBufferSizeInFrames(), std::memory_order_relaxed);
    if (stream_->requestStart() != oboe::Result::OK) { stream_->close(); stream_.reset(); return false; }
    return true;
}

void OboeOut::close() {
    if (stream_) {
        stream_->stop();
        stream_->close();
        stream_.reset();
    }
}

int OboeOut::freeFrames() const {
    long long h = head_.load(std::memory_order_relaxed), t = tail_.load(std::memory_order_acquire);
    return ringFrames_ - (int)(h - t);
}
int OboeOut::bufferedFrames() const {
    long long h = head_.load(std::memory_order_acquire), t = tail_.load(std::memory_order_acquire);
    return (int)(h - t);
}

int OboeOut::write(const float* in, int frames) {
    long long h = head_.load(std::memory_order_relaxed), t = tail_.load(std::memory_order_acquire);
    int n = std::min(frames, ringFrames_ - (int)(h - t));
    if (n <= 0) return 0;
    int start = (int)(h % ringFrames_);
    int first = std::min(n, ringFrames_ - start);
    std::memcpy(&ring_[(size_t)start * 2], in, sizeof(float) * 2 * (size_t)first);
    if (n > first) std::memcpy(&ring_[0], in + (size_t)first * 2, sizeof(float) * 2 * (size_t)(n - first));
    head_.store(h + n, std::memory_order_release);
    return n;
}

oboe::DataCallbackResult OboeOut::onAudioReady(oboe::AudioStream*, void* audioData, int32_t numFrames) {
    float* out = static_cast<float*>(audioData);
    long long t = tail_.load(std::memory_order_relaxed), h = head_.load(std::memory_order_acquire);
    int avail = (int)(h - t);
    int n = std::min<int>(avail, numFrames);
    if (n > 0) {
        int start = (int)(t % ringFrames_);
        int first = std::min(n, ringFrames_ - start);
        std::memcpy(out, &ring_[(size_t)start * 2], sizeof(float) * 2 * (size_t)first);
        if (n > first) std::memcpy(out + (size_t)first * 2, &ring_[0], sizeof(float) * 2 * (size_t)(n - first));
        tail_.store(t + n, std::memory_order_release);
        consumed_.fetch_add(n, std::memory_order_release);
    }
    if (n < numFrames) {
        std::memset(out + (size_t)n * 2, 0, sizeof(float) * 2 * (size_t)(numFrames - n));
        underruns_.fetch_add(1, std::memory_order_relaxed);
    }
    return oboe::DataCallbackResult::Continue;
}

void OboeOut::onErrorAfterClose(oboe::AudioStream*, oboe::Result) {
    // Device vanished (headphones unplugged, BT handoff...). The Kotlin render thread polls this flag and
    // calls open() again; nothing is rebuilt here so the error callback stays trivial.
    disconnected_.store(true, std::memory_order_release);
}

}  // namespace pdj
