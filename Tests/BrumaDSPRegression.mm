#include "../Shared/AudioUnit/Support/FilterDSPKernel.hpp"
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <thread>
#include <new>

static std::atomic<size_t> heapAllocations{0};
void* operator new(size_t size) {
    heapAllocations.fetch_add(1, std::memory_order_relaxed);
    if (void* memory = std::malloc(std::max<size_t>(1, size))) return memory;
    throw std::bad_alloc();
}
void* operator new[](size_t size) { return ::operator new(size); }
void operator delete(void* memory) noexcept { std::free(memory); }
void operator delete[](void* memory) noexcept { std::free(memory); }

static void require(bool ok, const char* label) {
    if (!ok) { std::fprintf(stderr, "FAIL: %s\n", label); std::exit(1); }
}

struct StereoBuffers {
    UInt32 count = 2;
    AudioBuffer buffers[2];
    float left[128]{}, right[128]{};
    StereoBuffers() {
        buffers[0] = {1, sizeof(left), left};
        buffers[1] = {1, sizeof(right), right};
    }
    AudioBufferList* list() { return reinterpret_cast<AudioBufferList*>(this); }
    void silence() { std::fill_n(left, 128, 0); std::fill_n(right, 128, 0); }
};

static void isolate(FilterDSPKernel& kernel) {
    kernel.setParameter(BrumaMix, 100);
    for (auto p : {BrumaEQBypass, BrumaDriveBypass, BrumaCompressorBypass,
                   BrumaModBypass, BrumaDelayBypass, BrumaReverbBypass}) kernel.setParameter(p, 1);
}

static void convolverRegression() {
    BrumaPartitionedConvolver convolver;
    convolver.init();
    BrumaIRBank bank;
    std::vector<float> ir(511), input(1800), output(input.size());
    for (size_t i = 0; i < ir.size(); ++i) ir[i] = std::sin(float(i) * 0.38f) * std::exp(-float(i) / 100) * 0.07f;
    for (size_t i = 0; i < input.size(); ++i) input[i] = std::sin(float(i) * 0.71f) * 0.3f;
    convolver.prepare(bank, ir.data(), nullptr, ir.size());
    float maxError = 0;
    for (size_t i = 0; i < input.size(); ++i) {
        float right;
        convolver.render(input[i], input[i], bank, output[i], right);
        double reference = 0;
        for (size_t tap = 0; tap < ir.size() && tap <= i; ++tap) reference += double(ir[tap]) * input[i - tap];
        maxError = std::max(maxError, std::abs(output[i] - float(reference)));
    }
    require(maxError < 0.0001f, "partitioned convolution equals direct reference");
    convolver.reset();
    for (int i = 0; i < 1800; ++i) {
        float l, r;
        convolver.render(0, 0, bank, l, r);
        require(l == 0 && r == 0, "convolver reset clears direct and spectral histories");
    }
    std::printf("PASS: convolution reference and reset (max error %.8f)\n", maxError);
}

static void driveAndDelayRegression() {
    auto kernel = std::make_unique<FilterDSPKernel>();
    kernel->init(2, 48000);
    StereoBuffers audio;
    kernel->setBuffers(audio.list(), audio.list());
    isolate(*kernel);
    kernel->setParameter(BrumaDriveBypass, 0);
    for (int model = 0; model < 8; ++model) {
        kernel->setParameter(BrumaDriveCharacter, model);
        for (int block = 0; block < 20; ++block) {
            audio.silence(); kernel->process(128, 0);
            for (float v : audio.left) require(v == 0, "all drive models preserve silence");
        }
    }
    kernel->setParameter(BrumaDriveCharacter, 5);
    kernel->setParameter(BrumaDriveMix, 0);
    for (int b = 0; b < 10; ++b) { audio.silence(); kernel->process(128, 0); }
    float dry[128];
    for (int i = 0; i < 128; ++i) audio.left[i] = dry[i] = std::sin(float(i) * 0.3f) * 0.4f;
    kernel->process(128, 0);
    for (int i = 0; i < 128; ++i) require(audio.left[i] == dry[i], "Screamer Mix=0 preserves dry");

    isolate(*kernel);
    kernel->setParameter(BrumaDelayBypass, 0);
    kernel->setParameter(BrumaDelayMode, 2);
    kernel->setParameter(BrumaDelayMix, 100);
    kernel->setParameter(BrumaDelayTime, 10);
    kernel->setParameter(BrumaDelayFeedback, 75);
    for (int b = 0; b < 10; ++b) { audio.silence(); kernel->process(128, 0); }
    kernel->reset();
    for (int b = 0; b < 40; ++b) {
        audio.silence(); if (b == 0) audio.left[0] = 1;
        kernel->process(128, 0);
        for (float v : audio.right) require(v == 0, "Dual Mono has no L-to-R crossover");
    }
    kernel->reset(); audio.silence(); kernel->process(128, 0);
    for (float v : audio.left) require(v == 0, "DSP reset clears delay tail");
    std::puts("PASS: drive silence, Screamer dry, Dual Mono and reset");
}

static void reverseRegression() {
    for (float sampleRate : {44100.0f, 48000.0f, 96000.0f}) {
        auto kernel = std::make_unique<FilterDSPKernel>(); kernel->init(2, sampleRate);
        StereoBuffers audio; kernel->setBuffers(audio.list(), audio.list());
        isolate(*kernel);
        kernel->setParameter(BrumaReverbBypass, 0);
        kernel->setParameter(BrumaReverbType, 6);
        kernel->setParameter(BrumaReverseTime, 300);
        kernel->setParameter(BrumaReverseCurve, 100);
        kernel->setParameter(BrumaReverseDensity, 100);
        kernel->setParameter(BrumaReverbDiffusion, 0);
        kernel->setParameter(BrumaReverbPredelay, 30);
        kernel->setParameter(BrumaReverbDucking, 0);
        kernel->setParameter(BrumaReverbMix, 100);
        for (int b = 0; b < 20; ++b) { audio.silence(); kernel->process(128, 0); }
        kernel->reset();
        double early = 0, late = 0;
        float peak = 0, finalTail = 0;
        const int blocks = int(sampleRate * 0.8f / 128) + 1;
        for (int b = 0; b < blocks; ++b) {
            audio.silence(); if (b == 0) audio.left[0] = audio.right[0] = 0.8f;
            const size_t before = heapAllocations.load(std::memory_order_relaxed);
            kernel->process(128, 0);
            require(heapAllocations.load(std::memory_order_relaxed) == before, "Reverse render does not allocate heap memory");
            for (int i = 0; i < 128; ++i) {
                const float time = float(b * 128 + i) / sampleRate;
                const float value = audio.left[i];
                require(std::isfinite(value), "Reverse Gate remains finite");
                if (time < 0.03f) require(value == 0, "Reverse predelay preserves initial silence");
                if (time >= 0.03f && time < 0.15f) early += double(value) * value;
                if (time >= 0.21f && time < 0.33f) late += double(value) * value;
                if (time > 0.53f) finalTail = std::max(finalTail, std::abs(value));
                peak = std::max(peak, std::abs(value));
            }
        }
        require(late > early * 5 && late > 0.00001, "Reverse reflection envelope grows toward gate end");
        require(peak < 2.4f && finalTail < 0.000001f, "Reverse FIR has bounded gain and finite tail");
        kernel->reset(); audio.silence(); kernel->process(128, 0);
        for (float value : audio.left) require(value == 0, "Reverse reset invalidates prior history");
        kernel->setParameter(BrumaReverseTime, 2000);
        kernel->setParameter(BrumaReverseCurve, 0);
        kernel->setParameter(BrumaReverseEndFade, 250);
        for (int b = 0; b < 24; ++b) {
            for (float& value : audio.left) value = 0.4f;
            for (float& value : audio.right) value = -0.4f;
            kernel->process(128, 0);
            for (float value : audio.left) require(std::isfinite(value), "Reverse automation extremes are finite");
        }
        std::printf("PASS: Reverse Gate %.0f Hz, late/early energy %.2f, peak %.5f, tail %.9f\n",
                    sampleRate, late / std::max(1e-20, early), peak, finalTail);
    }
}

class EventProbe : public DSPKernel {
public:
    unsigned frames = 0, writes = 0;
    void process(AUAudioFrameCount count, AUAudioFrameCount offset) override {
        require(offset + count <= 128, "events cannot render outside block"); frames += count;
    }
    void startRamp(AUParameterAddress, AUValue, AUAudioFrameCount) override { ++writes; }
};
static void eventRegression() {
    EventProbe probe;
    AudioTimeStamp timestamp{}; timestamp.mSampleTime = 100;
    AURenderEvent first{}, last{};
    first.head.eventType = AURenderEventParameter;
    first.head.eventSampleTime = 100;
    first.head.next = &last;
    last.head.eventType = AURenderEventParameter;
    last.head.eventSampleTime = 10000000000LL;
    probe.processWithEvents(&timestamp, 128, &first, nullptr);
    require(probe.frames == 128 && probe.writes == 1, "late/out-of-block event segmentation");
    std::puts("PASS: bounded render events");
}

static void irPublicationRegression() {
    auto kernel = std::make_unique<FilterDSPKernel>(); kernel->init(2, 48000);
    StereoBuffers audio; kernel->setBuffers(audio.list(), audio.list());
    isolate(*kernel); kernel->setParameter(BrumaReverbBypass, 0); kernel->setParameter(BrumaReverbIRBlend, 100);
    std::atomic<bool> done{false};
    std::thread writer([&] {
        float ir[256]{}; ir[0] = 0.8f; ir[130] = 0.15f;
        for (int i = 0; i < 500; ++i) {
            require(kernel->setImpulse(ir, nullptr, 256), "IR publication succeeds");
            if (i % 3 == 0) require(kernel->clearImpulse(), "IR clear succeeds");
        }
        done.store(true);
    });
    do {
        audio.silence(); audio.left[0] = 0.1f; kernel->process(128, 0);
        for (float v : audio.left) require(std::isfinite(v), "concurrent IR render stays finite");
    } while (!done.load());
    writer.join();
    std::puts("PASS: concurrent IR publish/clear/render");
}

int main() {
    convolverRegression(); driveAndDelayRegression(); reverseRegression(); eventRegression(); irPublicationRegression();
    std::puts("All DSP regressions passed.");
}
