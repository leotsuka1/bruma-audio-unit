/*
 Bruma's real-time stereo effects engine.

 All delay lines and working buffers are allocated by init(), before rendering.
 Parameter targets are atomic; the render thread owns all filter and envelope
 state. File loading writes to an inactive impulse-response bank and publishes
 it with an atomic index, so the render callback never takes a lock.
*/
#ifndef BrumaDSPKernel_hpp
#define BrumaDSPKernel_hpp

#import "DSPKernel.hpp"
#import "BrumaPartitionedConvolver.hpp"
#import <array>
#import <atomic>
#import <cmath>
#import <cstdint>
#import <vector>
#import <mutex>
#import <limits>

enum BrumaParameter : AUParameterAddress {
    BrumaMix = 0, BrumaRoom = 1, BrumaTone = 2,
    BrumaLegacyCutoff = 3, BrumaLegacyResonance = 4,
    BrumaStereoWidth = 5,
    BrumaEQBypass = 6, BrumaEQLow = 7, BrumaEQMid = 8, BrumaEQMidFrequency = 9, BrumaEQHigh = 10,
    BrumaDriveBypass = 11, BrumaDriveAmount = 12, BrumaDriveTone = 13, BrumaDriveMix = 14,
    BrumaCompressorBypass = 15, BrumaCompressorThreshold = 16, BrumaCompressorRatio = 17,
    BrumaCompressorAttack = 18, BrumaCompressorRelease = 19, BrumaCompressorMakeup = 20,
    BrumaModBypass = 21, BrumaModType = 22, BrumaModRate = 23, BrumaModDepth = 24, BrumaModFeedback = 25,
    BrumaDelayBypass = 26, BrumaDelayTime = 27, BrumaDelaySync = 28, BrumaDelayDivision = 29,
    BrumaDelayFeedback = 30, BrumaDelayTone = 31, BrumaDelayMix = 32, BrumaDelayWidth = 33,
    BrumaReverbBypass = 34, BrumaReverbType = 35, BrumaReverbDecay = 36, BrumaReverbPredelay = 37,
    BrumaReverbDiffusion = 38, BrumaReverbEarlyLate = 39, BrumaReverbDamping = 40,
    BrumaReverbLowCut = 41, BrumaReverbHighCut = 42, BrumaReverbModRate = 43,
    BrumaReverbModDepth = 44, BrumaReverbWidth = 45, BrumaReverbDucking = 46,
    BrumaReverbFreeze = 47, BrumaReverbIRBlend = 48, BrumaReverbShimmer = 49,
    BrumaOutputGain = 50, BrumaReverbMix = 51, BrumaEQMidQ = 52, BrumaReverbShimmerShift = 53,
    BrumaDriveCharacter = 54, BrumaCompressorKnee = 55, BrumaDelayPingPong = 56,
    BrumaDelayMode = 57, BrumaDelayLowCut = 58, BrumaDelayHighCut = 59,
    BrumaDelayDucking = 60, BrumaCompressorModel = 61,
    BrumaCompressorTapeAmount = 62, BrumaCompressorTapeSpeed = 63,
    BrumaReverseTime = 64, BrumaReverseCurve = 65, BrumaReverseDensity = 66,
    BrumaReverseLiveness = 67, BrumaReverseEndFade = 68, BrumaReverseLevel = 69
};

static constexpr AUParameterAddress BrumaParameterCount = 70;
static constexpr AUParameterAddress FilterParamCutoff = BrumaLegacyCutoff;
static constexpr AUParameterAddress FilterParamResonance = BrumaLegacyResonance;

static inline float brumaClamp(float x, float lo, float hi) {
    return std::min(std::max(x, lo), hi);
}

static inline bool brumaIsDiscreteParameter(AUParameterAddress p) {
    switch (p) {
        case BrumaEQBypass: case BrumaDriveBypass: case BrumaCompressorBypass:
        case BrumaModBypass: case BrumaModType: case BrumaDelayBypass:
        case BrumaDelaySync: case BrumaDelayDivision: case BrumaReverbBypass:
        case BrumaReverbType: case BrumaReverbFreeze: case BrumaDriveCharacter:
        case BrumaDelayMode: case BrumaCompressorModel: case BrumaCompressorTapeSpeed:
            return true;
        default: return false;
    }
}

static inline float brumaSanitizeParameter(AUParameterAddress p, float value) {
    if (!std::isfinite(value)) return 0.0f;
    switch (p) {
        case BrumaMix: case BrumaRoom: case BrumaTone: case BrumaLegacyCutoff:
        case BrumaLegacyResonance: case BrumaDriveTone: case BrumaDriveMix:
        case BrumaModDepth: case BrumaModFeedback: case BrumaDelayTone:
        case BrumaDelayMix: case BrumaReverbDiffusion: case BrumaReverbEarlyLate:
        case BrumaReverbDamping: case BrumaReverbModDepth: case BrumaReverbDucking:
        case BrumaReverbIRBlend: case BrumaReverbShimmer: case BrumaReverbMix:
        case BrumaDelayDucking: case BrumaCompressorTapeAmount:
        case BrumaReverseCurve: case BrumaReverseDensity:
            return brumaClamp(value, 0.0f, 100.0f);
        case BrumaStereoWidth: case BrumaDelayWidth: case BrumaReverbWidth:
            return brumaClamp(value, 0.0f, 150.0f);
        case BrumaEQBypass: case BrumaDriveBypass: case BrumaCompressorBypass:
        case BrumaModBypass: case BrumaDelayBypass: case BrumaDelaySync:
        case BrumaReverbBypass: case BrumaReverbFreeze:
            return value >= 0.5f ? 1.0f : 0.0f;
        case BrumaEQLow: case BrumaEQMid: case BrumaEQHigh: return brumaClamp(value, -18.0f, 18.0f);
        case BrumaEQMidFrequency: return brumaClamp(value, 80.0f, 12000.0f);
        case BrumaEQMidQ: return brumaClamp(value, 0.3f, 5.0f);
        case BrumaDriveAmount: return brumaClamp(value, 0.0f, 24.0f);
        case BrumaCompressorThreshold: return brumaClamp(value, -48.0f, 0.0f);
        case BrumaCompressorRatio: return brumaClamp(value, 1.0f, 20.0f);
        case BrumaCompressorAttack: return brumaClamp(value, 0.1f, 100.0f);
        case BrumaCompressorRelease: return brumaClamp(value, 10.0f, 1000.0f);
        case BrumaCompressorMakeup: return brumaClamp(value, 0.0f, 24.0f);
        case BrumaModRate: case BrumaReverbModRate: return brumaClamp(value, 0.05f, 8.0f);
        case BrumaDelayTime: return brumaClamp(value, 1.0f, 2000.0f);
        case BrumaDelayFeedback: return brumaClamp(value, 0.0f, 94.0f);
        case BrumaReverbDecay: return brumaClamp(value, 0.1f, 30.0f);
        case BrumaReverbPredelay: return brumaClamp(value, 0.0f, 300.0f);
        case BrumaReverbLowCut: case BrumaDelayLowCut: return brumaClamp(value, 20.0f, 1000.0f);
        case BrumaReverbHighCut: case BrumaDelayHighCut: return brumaClamp(value, 2000.0f, 20000.0f);
        case BrumaOutputGain: return brumaClamp(value, -24.0f, 12.0f);
        case BrumaReverbShimmerShift: return brumaClamp(value, 7.0f, 24.0f);
        case BrumaDriveCharacter: return brumaClamp(std::round(value), 0.0f, 7.0f);
        case BrumaModType: return brumaClamp(std::round(value), 0.0f, 1.0f);
        case BrumaDelayDivision: return brumaClamp(std::round(value), 0.0f, 9.0f);
        case BrumaReverbType: return brumaClamp(std::round(value), 0.0f, 6.0f);
        case BrumaCompressorKnee: return brumaClamp(value, 0.0f, 18.0f);
        case BrumaDelayPingPong: return brumaClamp(value, 0.0f, 100.0f);
        case BrumaDelayMode: return brumaClamp(std::round(value), 0.0f, 3.0f);
        case BrumaCompressorModel: return brumaClamp(std::round(value), 0.0f, 4.0f);
        case BrumaCompressorTapeSpeed: return brumaClamp(std::round(value), 0.0f, 2.0f);
        case BrumaReverseTime: return brumaClamp(value, 50.0f, 2000.0f);
        case BrumaReverseLiveness: return brumaClamp(value, 0.0f, 10.0f);
        case BrumaReverseEndFade: return brumaClamp(value, 1.0f, 250.0f);
        case BrumaReverseLevel: return brumaClamp(value, -12.0f, 12.0f);
        default: return value;
    }
}

class FilterDSPKernel : public DSPKernel {
public:
    FilterDSPKernel() {
        const float defaults[BrumaParameterCount] = {
            28, 58, 42, 28, 58, 100,
            0, 0, 0, 900, 0,
            0, 4, 50, 100,
            0, -18, 3, 18, 180, 0,
            0, 0, 0.8f, 45, 20,
            0, 420, 0, 0, 32, 45, 25, 100,
            0, 1, 2.8f, 24, 78, 50, 42, 80, 16500, 0.25f, 18, 100, 8, 0, 0, 0,
            0, 100, 1.0f, 12.0f,
            0, 6, 0,
            0, 60, 15000, 0, 0, 32, 1,
            450, 70, 75, 5, 12, 0
        };
        for (AUParameterAddress i = 0; i < BrumaParameterCount; ++i) {
            targets[i].store(defaults[i], std::memory_order_relaxed);
            parameterValues[i].store(defaults[i], std::memory_order_relaxed);
            observed[i] = defaults[i];
            current[i] = defaults[i];
            goal[i] = defaults[i];
        }
    }

    void init(int channelCount, double rate) {
        sampleRate = float(rate);
        channels = std::max(1, std::min(channelCount, 2));
        const size_t delaySize = std::max<size_t>(4, size_t(sampleRate * 4.05));
        delayL.assign(delaySize, 0.0f);
        delayR.assign(delaySize, 0.0f);
        modulationL.assign(std::max<size_t>(4, size_t(sampleRate * 0.15)), 0.0f);
        modulationR.assign(modulationL.size(), 0.0f);
        modulationIndex = delayIndex = 0;
        reverseL.assign(size_t(sampleRate * 2.4f) + 4, 0.0f);
        reverseR.assign(reverseL.size(), 0.0f);
        resetReverse();

        for (size_t i = 0; i < reverbLines.size(); ++i) {
            static const float ms[8] = {29.7f, 37.1f, 41.1f, 43.7f, 53.1f, 59.3f, 67.7f, 71.9f};
            reverbLines[i].assign(size_t(sampleRate * ms[i] / 1000.0f * 1.65f) + 8, 0.0f);
            reverbIndices[i] = 0;
            reverbDamping[i] = 0.0f;
        }
        convolver.init();
        activeIR.store(0, std::memory_order_release);
        for (auto& readers : irReaders) readers.store(0, std::memory_order_relaxed);
        convolverBank = -1;

        eqLowL = eqLowR = 0.0f;
        eqHighL = eqHighR = 0.0f;
        drivePreviousL = drivePreviousR = 0.0f;
        compressorEnvelope = 0.0f;
        delayToneL = delayToneR = delayHighPassL = delayHighPassR = 0.0f;
        delayDuckEnvelope = 0.0f;
        reverbDuckEnvelope = 0.0f;
        reverbPredelayL.assign(size_t(sampleRate * 0.31f) + 4, 0.0f);
        reverbPredelayR.assign(reverbPredelayL.size(), 0.0f);
        shimmerLineL.assign(size_t(sampleRate * 0.15f) + 4, 0.0f);
        shimmerLineR.assign(shimmerLineL.size(), 0.0f);
        predelayIndex = 0;
        shimmerWriteIndex = 0;
        shimmerPhase = 0.0f;
        modPhase = reverbPhase = 0.0;
        eqMidL = Biquad{};
        eqMidR = Biquad{};
        driveToneL = driveToneR = 0.0f;
        driveScreamerLowL = driveScreamerLowR = driveScreamerMidL = driveScreamerMidR = 0.0f;
        compressorTapeLowL = compressorTapeLowR = 0.0f;
        compressorEnvelopeDB = -120.0f;
        updateEQCoefficients();
        updateDriveCoefficients();
        updateDelayCoefficients();
        updateCompressorCoefficients();
        updateReverbCoefficients();
        updateShimmerPitch();
        inputPeak.store(0.0f);
        outputPeak.store(0.0f);
        dezipperSamples = std::max<AUAudioFrameCount>(1, AUAudioFrameCount(sampleRate * 0.012));
        bypassed.store(false, std::memory_order_relaxed);
    }

    void reset() {
        resetReverse();
        std::fill(delayL.begin(), delayL.end(), 0.0f);
        std::fill(delayR.begin(), delayR.end(), 0.0f);
        std::fill(modulationL.begin(), modulationL.end(), 0.0f);
        std::fill(modulationR.begin(), modulationR.end(), 0.0f);
        for (auto& line : reverbLines) std::fill(line.begin(), line.end(), 0.0f);
        std::fill(reverbPredelayL.begin(), reverbPredelayL.end(), 0.0f);
        std::fill(reverbPredelayR.begin(), reverbPredelayR.end(), 0.0f);
        std::fill(shimmerLineL.begin(), shimmerLineL.end(), 0.0f);
        std::fill(shimmerLineR.begin(), shimmerLineR.end(), 0.0f);
        delayIndex = modulationIndex = predelayIndex = 0;
        std::fill(reverbIndices.begin(), reverbIndices.end(), 0);
        reverbDamping.fill(0.0f);
        shimmerWriteIndex = 0;
        shimmerPhase = 0.0f;
        modPhase = reverbPhase = 0.0;
        convolver.reset();
        convolverBank = -1;
        irConvolutionActive = false;
        compressorEnvelope = 0.0f;
        compressorEnvelopeDB = -120.0f;
        delayToneL = delayToneR = delayHighPassL = delayHighPassR = 0.0f;
        delayDuckEnvelope = 0.0f;
        reverbDuckEnvelope = 0.0f;
        driveScreamerLowL = driveScreamerLowR = driveScreamerMidL = driveScreamerMidR = 0.0f;
        compressorTapeLowL = compressorTapeLowR = 0.0f;
        eqLowL = eqLowR = eqHighL = eqHighR = 0.0f;
        eqMidL = Biquad{}; eqMidR = Biquad{};
        drivePreviousL = drivePreviousR = driveToneL = driveToneR = 0.0f;
        reverbLowL = reverbLowR = reverbHighL = reverbHighR = 0.0f;
        inputPeak.store(0.0f, std::memory_order_relaxed);
        outputPeak.store(0.0f, std::memory_order_relaxed);
    }

    bool isBypassed() const { return bypassed.load(std::memory_order_relaxed); }
    void setBypass(bool value) { bypassed.store(value, std::memory_order_relaxed); }

    void setParameter(AUParameterAddress address, AUValue value) {
        if (address >= BrumaParameterCount) return;
        const AUParameterAddress originalAddress = address;
        if (address == BrumaLegacyCutoff) address = BrumaMix;
        else if (address == BrumaLegacyResonance) address = BrumaRoom;
        value = brumaSanitizeParameter(address, value);
        parameterValues[originalAddress].store(value, std::memory_order_release);
        targets[address].store(value, std::memory_order_release);
        if (originalAddress == BrumaTone) targets[BrumaReverbDamping].store(value, std::memory_order_release);
    }

    AUValue getParameter(AUParameterAddress address) const {
        if (address >= BrumaParameterCount) return 0.0f;
        return parameterValues[address].load(std::memory_order_acquire);
    }

    void startRamp(AUParameterAddress address, AUValue value, AUAudioFrameCount duration) override {
        const AUParameterAddress alias = address;
        if (address == BrumaLegacyCutoff) address = BrumaMix;
        if (address == BrumaLegacyResonance) address = BrumaRoom;
        if (address >= BrumaParameterCount) return;
        value = brumaSanitizeParameter(address, value);
        parameterValues[alias].store(value, std::memory_order_release);
        if (alias != address) targets[alias].store(value, std::memory_order_release);
        targets[address].store(value, std::memory_order_release);
        observed[address] = value;
        targetEvent(address, value, brumaIsDiscreteParameter(address) ? 0 : duration);
        if (alias == BrumaTone) {
            targets[BrumaReverbDamping].store(value, std::memory_order_release);
            observed[BrumaReverbDamping] = value;
            targetEvent(BrumaReverbDamping, value, duration);
        }
    }

    // Only loading/control threads take this lock. A reserved bank cannot
    // be leased by render, even if render retained a stale active index.
    bool setImpulse(const float* left, const float* right, size_t count) {
        if (left == nullptr || count == 0) return false;
        std::lock_guard<std::mutex> lock(irWriterMutex);
        const int bank = reserveIRBank();
        if (bank < 0) return false;
        try {
            convolver.prepare(irBanks[bank], left, right, std::min(count, BrumaIRCapacity));
        } catch (...) {
            irReaders[bank].store(0, std::memory_order_release);
            return false;
        }
        irReaders[bank].store(0, std::memory_order_release);
        activeIR.store(bank, std::memory_order_release);
        return true;
    }

    bool clearImpulse() {
        std::lock_guard<std::mutex> lock(irWriterMutex);
        const int bank = reserveIRBank();
        if (bank < 0) return false;
        irBanks[bank].sampleCount = irBanks[bank].partitionCount = 0;
        irReaders[bank].store(0, std::memory_order_release);
        activeIR.store(bank, std::memory_order_release);
        return true;
    }

    float meterInput() const { return inputPeak.load(std::memory_order_relaxed); }
    float meterOutput() const { return outputPeak.load(std::memory_order_relaxed); }
    void setTempo(double bpm) { if (bpm >= 30.0 && bpm <= 300.0) tempo.store(float(bpm), std::memory_order_release); }

    void setBuffers(AudioBufferList* in, AudioBufferList* out) {
        inBufferListPtr = in;
        outBufferListPtr = out;
    }

    void process(AUAudioFrameCount frameCount, AUAudioFrameCount bufferOffset) override {
        if (!inBufferListPtr || !outBufferListPtr || inBufferListPtr->mNumberBuffers == 0 ||
            outBufferListPtr->mNumberBuffers == 0) return;

        // Observe UI parameter updates and dezipper them over 12 ms.
        for (AUParameterAddress p = 0; p < BrumaParameterCount; ++p) {
            float target = targets[p].load(std::memory_order_acquire);
            if (target != observed[p]) {
                observed[p] = target;
                target = brumaSanitizeParameter(p, target);
                targetEvent(p, target, brumaIsDiscreteParameter(p) ? 0 : dezipperSamples);
            }
        }

        int irBankIndex = -1;
        // Bounded acquisition: render never waits for a writer. If all three
        // attempts lose to publication, this segment uses the algorithmic tail.
        for (int attempt = 0; attempt < 3; ++attempt) {
            const int candidate = activeIR.load(std::memory_order_acquire);
            uint32_t expected = 0;
            if (!irReaders[candidate].compare_exchange_strong(expected, 1, std::memory_order_acq_rel)) continue;
            if (candidate == activeIR.load(std::memory_order_acquire)) {
                irBankIndex = candidate;
                break;
            }
            irReaders[candidate].store(0, std::memory_order_release);
        }
        if (convolverBank != irBankIndex) {
            convolver.reset();
            convolverBank = irBankIndex;
            irConvolutionActive = false;
        }
        const BrumaIRBank& impulse = irBankIndex >= 0 ? irBanks[irBankIndex] : emptyIRBank;

        float inPeakBlock = 0.0f, outPeakBlock = 0.0f;
        for (AUAudioFrameCount i = 0; i < frameCount; ++i) {
            if ((i & 15u) == 0) {
                updateEQCoefficients();
                updateDriveCoefficients();
                updateDelayCoefficients();
                updateCompressorCoefficients();
                updateReverbCoefficients();
                updateShimmerPitch();
                updateReverseCoefficients();
            }
            const AUAudioFrameCount frame = i + bufferOffset;
            float* inL = static_cast<float*>(inBufferListPtr->mBuffers[0].mData) + frame;
            float* outL = static_cast<float*>(outBufferListPtr->mBuffers[0].mData) + frame;
            float* inR = inBufferListPtr->mNumberBuffers > 1 ? static_cast<float*>(inBufferListPtr->mBuffers[1].mData) + frame : inL;
            float* outR = outBufferListPtr->mNumberBuffers > 1 ? static_cast<float*>(outBufferListPtr->mBuffers[1].mData) + frame : outL;
            float l = *inL, r = *inR;
            inPeakBlock = std::max(inPeakBlock, std::max(std::abs(l), std::abs(r)));

            if (bypassed.load(std::memory_order_relaxed)) {
                *outL = l; if (outR != outL) *outR = r;
                outPeakBlock = std::max(outPeakBlock, std::max(std::abs(l), std::abs(r)));
                advanceAll();
                continue;
            }

            const float mix = unit(step(BrumaMix));
            const float width = widthUnit(step(BrumaStereoWidth));
            const float originalL = l, originalR = r;
            stereoStage(l, r, width);
            if (step(BrumaEQBypass) < 0.5f) equalize(l, r);
            if (step(BrumaDriveBypass) < 0.5f) drive(l, r);
            if (step(BrumaCompressorBypass) < 0.5f) compress(l, r);
            if (step(BrumaModBypass) < 0.5f) modulate(l, r);
            if (step(BrumaDelayBypass) < 0.5f) delay(l, r);
            if (step(BrumaReverbBypass) < 0.5f) reverb(l, r, impulse);

            const float outGain = dbToLinear(step(BrumaOutputGain));
            l = originalL * (1.0f - mix) + l * mix;
            r = originalR * (1.0f - mix) + r * mix;
            l *= outGain; r *= outGain;
            l = finite(l); r = finite(r);
            *outL = l; if (outR != outL) *outR = r;
            outPeakBlock = std::max(outPeakBlock, std::max(std::abs(l), std::abs(r)));
            advanceAll();
        }
        inputPeak.store(inPeakBlock, std::memory_order_relaxed);
        outputPeak.store(outPeakBlock, std::memory_order_relaxed);
        if (irBankIndex >= 0) irReaders[irBankIndex].store(0, std::memory_order_release);
    }

private:
    int reserveIRBank() {
        const int active = activeIR.load(std::memory_order_acquire);
        for (int offset = 1; offset < int(irBanks.size()); ++offset) {
            const int candidate = (active + offset) % int(irBanks.size());
            uint32_t expected = 0;
            if (irReaders[candidate].compare_exchange_strong(expected, std::numeric_limits<uint32_t>::max(),
                                                            std::memory_order_acq_rel)) return candidate;
        }
        return -1;
    }

    struct Biquad {
        float z1 = 0, z2 = 0;
        float process(float x, float b0, float b1, float b2, float a1, float a2) {
            float y = b0 * x + z1;
            z1 = b1 * x - a1 * y + z2;
            z2 = b2 * x - a2 * y;
            return y;
        }
    };

    void updateEQCoefficients() {
        const float frequency = brumaClamp(step(BrumaEQMidFrequency), 80.0f, std::min(12000.0f, sampleRate * 0.45f));
        const float gainDB = step(BrumaEQMid);
        const float q = brumaClamp(step(BrumaEQMidQ), 0.3f, 5.0f);
        eqLowGain = dbToLinear(step(BrumaEQLow));
        eqHighGain = dbToLinear(step(BrumaEQHigh));
        eqLowAlpha = onePole(160.0f, sampleRate);
        eqHighAlpha = onePole(std::min(6500.0f, sampleRate * 0.35f), sampleRate);
        const float amplitude = std::pow(10.0f, gainDB / 40.0f);
        const float omega = 2.0f * float(M_PI) * frequency / sampleRate;
        const float cosine = std::cos(omega);
        const float alpha = std::sin(omega) / (2.0f * q);
        const float a0 = 1.0f + alpha / amplitude;
        eqMidB0 = (1.0f + alpha * amplitude) / a0;
        eqMidB1 = (-2.0f * cosine) / a0;
        eqMidB2 = (1.0f - alpha * amplitude) / a0;
        eqMidA1 = (-2.0f * cosine) / a0;
        eqMidA2 = (1.0f - alpha / amplitude) / a0;
    }

    void updateDriveCoefficients() {
        driveGain = dbToLinear(brumaClamp(step(BrumaDriveAmount), 0.0f, 24.0f));
        const float character = step(BrumaDriveCharacter);
        const auto curve = [character](float x) {
            if (character < 0.5f) return std::tanh(x);                         // smooth
            if (character < 1.5f) return 0.82f * std::tanh(x + 0.22f) + 0.18f * std::tanh(x * 2.4f); // tube
            if (character < 2.5f) return x / (1.0f + 0.72f * std::abs(x));   // tape
            if (character < 3.5f) return std::tanh(x * 1.55f);               // dense
            if (character < 4.5f) return std::max(-0.92f, std::min(0.92f, x)); // console
            if (character < 5.5f) return std::tanh(x * 1.3f);               // mid-drive
            if (character < 6.5f) return x / (1.0f + 0.48f * std::abs(x));  // transparent OD
            return std::tanh(x * 2.8f + 0.08f);                              // fuzz
        };
        driveCurveKind = int(character + 0.5f);
        driveBias = curve(0.0f);
        driveNormalization = std::max(0.05f, std::abs(curve(driveGain) - driveBias));
        driveToneAlpha = onePole(500.0f + unit(step(BrumaDriveTone)) * 15000.0f, sampleRate);
        driveScreamerLowAlpha = onePole(140.0f, sampleRate);
        driveScreamerMidAlpha = onePole(720.0f, sampleRate);
    }

    void updateDelayCoefficients() {
        const float toneCutoff = 400.0f + unit(step(BrumaDelayTone)) * 15000.0f;
        delayColorAlpha = onePole(std::min(toneCutoff, brumaClamp(step(BrumaDelayHighCut), 2000.0f, sampleRate * 0.48f)), sampleRate);
        delayHighPassAlpha = onePole(brumaClamp(step(BrumaDelayLowCut), 20.0f, 1000.0f), sampleRate);
        delayDuckAttackAlpha = 1.0f - std::exp(-1.0f / (0.003f * sampleRate));
        delayDuckReleaseAlpha = 1.0f - std::exp(-1.0f / (0.16f * sampleRate));
    }

    void updateCompressorCoefficients() {
        compressorThresholdCached = step(BrumaCompressorThreshold);
        compressorRatioCached = std::max(1.0f, step(BrumaCompressorRatio));
        const int model = int(step(BrumaCompressorModel) + 0.5f);
        float attackMs = step(BrumaCompressorAttack);
        float releaseMs = step(BrumaCompressorRelease);
        if (model == 2) { attackMs *= 0.45f; releaseMs *= 0.75f; } // FET
        if (model == 3) { attackMs = std::max(attackMs, 12.0f); releaseMs *= 1.35f; } // opto
        if (model == 4) { attackMs = std::max(attackMs, 10.0f); releaseMs = std::max(releaseMs, 120.0f); } // tape
        compressorAttackAlpha = 1.0f - std::exp(-1.0f / (std::max(0.1f, attackMs) * 0.001f * sampleRate));
        compressorReleaseAlpha = 1.0f - std::exp(-1.0f / (std::max(1.0f, releaseMs) * 0.001f * sampleRate));
        compressorMakeup = dbToLinear(step(BrumaCompressorMakeup));
        const float tapeSpeed = step(BrumaCompressorTapeSpeed);
        const float tapeCutoff = tapeSpeed < 0.5f ? 9000.0f : (tapeSpeed < 1.5f ? 14500.0f : 19500.0f);
        compressorTapeAlpha = onePole(std::min(tapeCutoff, sampleRate * 0.46f), sampleRate);
    }

    void updateReverbCoefficients() {
        const float sizeScale = 0.65f + unit(step(BrumaRoom)) * 0.8f;
        const float decay = brumaClamp(step(BrumaReverbDecay), 0.1f, 30.0f);
        const float mode = step(BrumaReverbType);
        const float modeScale = mode < 0.5f ? 0.72f : (mode < 1.5f ? 1.25f : (mode < 2.5f ? 0.92f : (mode < 3.5f ? 0.56f : 0.56f)));
        float meanDelay = 0.0f;
        for (size_t i = 0; i < reverbLines.size(); ++i) {
            meanDelay += float(reverbLines[i].size() - 8) * (0.57f + float(i) * 0.037f) * modeScale * sizeScale;
        }
        meanDelay /= float(reverbLines.size());
        // Tune the feedback to the actual delay lengths and requested RT60.
        // The FDN matrix is energy preserving, so circulation stays below 1.
        reverbFeedbackGain = brumaClamp(std::pow(10.0f, -3.0f * meanDelay / (sampleRate * decay)), 0.0f, 0.9995f);
        reverbLowAlpha = onePole(brumaClamp(step(BrumaReverbLowCut), 20.0f, 1000.0f), sampleRate);
        reverbHighAlpha = onePole(brumaClamp(step(BrumaReverbHighCut), 2000.0f, sampleRate * 0.48f), sampleRate);
        reverbDuckAttackAlpha = 1.0f - std::exp(-1.0f / (0.008f * sampleRate));
        reverbDuckReleaseAlpha = 1.0f - std::exp(-1.0f / (0.22f * sampleRate));
    }

    void updateShimmerPitch() {
        shimmerWindowSamples = std::max(128.0f, sampleRate * 0.12f);
        const float ratio = std::pow(2.0f, brumaClamp(step(BrumaReverbShimmerShift), 7.0f, 24.0f) / 12.0f);
        shimmerPhaseIncrement = (ratio - 1.0f) / shimmerWindowSamples;
    }

    static float finite(float x) { return std::isfinite(x) && std::abs(x) < 1.0e6f ? x : 0.0f; }
    static float unit(float x) { return brumaClamp(x * 0.01f, 0.0f, 1.0f); }
    static float widthUnit(float x) { return brumaClamp(x * 0.01f, 0.0f, 1.5f); }
    static float dbToLinear(float dB) { return std::pow(10.0f, dB / 20.0f); }
    static float onePole(float hz, float sr) { return 1.0f - std::exp(-2.0f * float(M_PI) * hz / sr); }

    void targetEvent(AUParameterAddress p, float value, AUAudioFrameCount duration) {
        if (p >= BrumaParameterCount) return;
        if (duration == 0) { current[p] = goal[p] = value; remaining[p] = 0; slope[p] = 0; }
        else {
            goal[p] = value;
            remaining[p] = duration;
            slope[p] = (current[p] - value) / float(duration);
        }
    }
    float step(AUParameterAddress p) {
        return current[p];
    }
    void advanceAll() {
        for (AUParameterAddress p = 0; p < BrumaParameterCount; ++p) {
            if (remaining[p] > 0) {
                --remaining[p];
                if (remaining[p] == 0) current[p] = goal[p];
                else current[p] -= slope[p];
            }
        }
    }

    void stereoStage(float& l, float& r, float amount) {
        float mid = 0.5f * (l + r);
        float side = 0.5f * (l - r) * amount;
        l = mid + side; r = mid - side;
    }

    void equalize(float& l, float& r) {
        eqLowL += eqLowAlpha * (l - eqLowL); eqLowR += eqLowAlpha * (r - eqLowR);
        eqHighL += eqHighAlpha * (l - eqHighL); eqHighR += eqHighAlpha * (r - eqHighR);
        l += eqLowL * (eqLowGain - 1.0f) + (l - eqHighL) * (eqHighGain - 1.0f);
        r += eqLowR * (eqLowGain - 1.0f) + (r - eqHighR) * (eqHighGain - 1.0f);
        l = eqMidL.process(l, eqMidB0, eqMidB1, eqMidB2, eqMidA1, eqMidA2);
        r = eqMidR.process(r, eqMidB0, eqMidB1, eqMidB2, eqMidA1, eqMidA2);
    }

    float shape(float x) {
        const float driven = x * driveGain;
        float shaped = 0.0f;
        switch (driveCurveKind) {
            case 1: shaped = 0.82f * std::tanh(driven + 0.22f) + 0.18f * std::tanh(driven * 2.4f); break;
            case 2: shaped = driven / (1.0f + 0.72f * std::abs(driven)); break;
            case 3: shaped = std::tanh(driven * 1.55f); break;
            case 4: shaped = std::max(-0.92f, std::min(0.92f, driven)); break;
            case 5: shaped = std::tanh(driven * 1.3f); break;
            case 6: shaped = driven / (1.0f + 0.48f * std::abs(driven)); break;
            case 7: shaped = std::tanh(driven * 2.8f + 0.08f); break;
            default: shaped = std::tanh(driven); break;
        }
        return (shaped - driveBias) / driveNormalization;
    }
    void drive(float& l, float& r) {
        const float dryL = l, dryR = r;
        float tone = unit(step(BrumaDriveTone));
        float wet = unit(step(BrumaDriveMix));
        if (driveCurveKind == 5) {
            // Tube Screamer inspired pre-emphasis: tighten bass and lift the
            // 700 Hz body before clipping, then let Drive Tone shape the top.
            driveScreamerLowL += driveScreamerLowAlpha * (l - driveScreamerLowL);
            driveScreamerLowR += driveScreamerLowAlpha * (r - driveScreamerLowR);
            driveScreamerMidL += driveScreamerMidAlpha * (l - driveScreamerMidL);
            driveScreamerMidR += driveScreamerMidAlpha * (r - driveScreamerMidR);
            l = (l - driveScreamerLowL) * 0.72f + (driveScreamerMidL - driveScreamerLowL) * 0.58f;
            r = (r - driveScreamerLowR) * 0.72f + (driveScreamerMidR - driveScreamerLowR) * 0.58f;
        }
        // Four-times linear interpolation followed by a short symmetric
        // decimation FIR reduces foldback without allocating render buffers.
        const float positions[4] = {0.125f, 0.375f, 0.625f, 0.875f};
        const float weights[4] = {0.125f, 0.375f, 0.375f, 0.125f};
        float satL = 0.0f, satR = 0.0f;
        for (size_t i = 0; i < 4; ++i) {
            float sampleL = drivePreviousL + (l - drivePreviousL) * positions[i];
            float sampleR = drivePreviousR + (r - drivePreviousR) * positions[i];
            satL += shape(sampleL) * weights[i];
            satR += shape(sampleR) * weights[i];
        }
        drivePreviousL = l; drivePreviousR = r;
        driveToneL += driveToneAlpha * (satL - driveToneL); driveToneR += driveToneAlpha * (satR - driveToneR);
        satL = satL * tone + driveToneL * (1.0f - tone);
        satR = satR * tone + driveToneR * (1.0f - tone);
        l = dryL * (1.0f - wet) + satL * wet;
        r = dryR * (1.0f - wet) + satR * wet;
    }

    void compress(float& l, float& r) {
        const int model = int(step(BrumaCompressorModel) + 0.5f);
        if (model == 4) {
            const float amount = unit(step(BrumaCompressorTapeAmount));
            const float drive = 1.0f + amount * 2.5f;
            const float satL = std::tanh(l * drive) / drive;
            const float satR = std::tanh(r * drive) / drive;
            compressorTapeLowL += compressorTapeAlpha * (satL - compressorTapeLowL);
            compressorTapeLowR += compressorTapeAlpha * (satR - compressorTapeLowR);
            const float tapeColor = amount;
            const float speedColor = step(BrumaCompressorTapeSpeed) < 0.5f ? 0.25f : 0.12f;
            const float coloredL = satL * (1.0f - speedColor) + compressorTapeLowL * speedColor;
            const float coloredR = satR * (1.0f - speedColor) + compressorTapeLowR * speedColor;
            l += (coloredL - l) * tapeColor;
            r += (coloredR - r) * tapeColor;
        }
        const float peak = std::max(std::abs(l), std::abs(r));
        float level = peak;
        if (model == 1 || model == 3 || model == 4) {
            const float rmsAlpha = onePole(model == 3 ? 28.0f : 12.0f, sampleRate);
            const float power = 0.5f * (l * l + r * r);
            compressorEnvelope += rmsAlpha * (power - compressorEnvelope);
            level = std::sqrt(std::max(1.0e-14f, compressorEnvelope));
        } else {
            compressorEnvelope = peak * peak;
        }
        level = std::max(1.0e-7f, level);
        const float ms = 20.0f * std::log10(level);
        const float coeff = ms > compressorEnvelopeDB ? compressorAttackAlpha : compressorReleaseAlpha;
        compressorEnvelopeDB += coeff * (ms - compressorEnvelopeDB);
        const float over = compressorEnvelopeDB - compressorThresholdCached;
        const float knee = model == 4 ? std::max(9.0f, step(BrumaCompressorKnee)) : step(BrumaCompressorKnee);
        float reduction = 0.0f;
        const float slope = 1.0f - 1.0f / compressorRatioCached;
        if (knee > 0.0f && over > -knee * 0.5f) {
            const float inKnee = brumaClamp(over + knee * 0.5f, 0.0f, knee);
            reduction = slope * inKnee * inKnee / (2.0f * knee);
            if (over > knee * 0.5f) reduction += slope * (over - knee * 0.5f);
        } else if (over > 0.0f) reduction = over * slope;
        const float gain = std::exp2(-reduction * 0.1660964f) * compressorMakeup;
        l *= gain; r *= gain;
    }

    void modulate(float& l, float& r) {
        const float mode = step(BrumaModType);
        const float rate = brumaClamp(step(BrumaModRate), 0.05f, 8.0f);
        const float depth = unit(step(BrumaModDepth));
        const float feedback = unit(step(BrumaModFeedback)) * 0.72f;
        modPhase += 2.0 * M_PI * rate / sampleRate;
        if (modPhase > 2.0 * M_PI) modPhase -= 2.0 * M_PI;
        float base = mode < 0.5f ? 0.016f : 0.002f;
        float range = mode < 0.5f ? 0.020f : 0.006f;
        const auto readMod = [&](const std::vector<float>& line, float phase) {
            const float lfo = 0.5f + 0.5f * std::sin(float(modPhase) + phase);
            const float delaySamples = brumaClamp((base + depth * range * lfo) * sampleRate, 1.0f, float(line.size() - 2));
            const size_t wholeDelay = size_t(delaySamples);
            const float fraction = delaySamples - float(wholeDelay);
            const size_t read = (modulationIndex + line.size() - wholeDelay) % line.size();
            const size_t older = (read + line.size() - 1) % line.size();
            return line[read] * (1.0f - fraction) + line[older] * fraction;
        };
        // Quadrature modulation widens the image while keeping both channels stable.
        float wetL = readMod(modulationL, 0.0f);
        float wetR = readMod(modulationR, float(M_PI) * 0.5f);
        modulationL[modulationIndex] = l + wetR * feedback;
        modulationR[modulationIndex] = r + wetL * feedback;
        modulationIndex = (modulationIndex + 1) % modulationL.size();
        float wet = mode < 0.5f ? 0.5f : 0.55f;
        l = l * (1.0f - wet) + wetL * wet;
        r = r * (1.0f - wet) + wetR * wet;
    }

    float delaySamples() {
        float milliseconds = step(BrumaDelayTime);
        if (step(BrumaDelaySync) >= 0.5f) {
            // Existing indices 0–7 are retained for saved sessions. Indices
            // 8–9 provide correctly timed triplets without remapping old states.
            static const float beatFractions[10] = {1.0f, 0.75f, 0.5f, 0.25f, 2.0f / 3.0f, 0.375f, 1.0f / 3.0f, 0.125f, 1.0f / 3.0f, 1.0f / 6.0f};
            int division = int(brumaClamp(step(BrumaDelayDivision), 0.0f, 9.0f));
            milliseconds = 60000.0f / tempo.load(std::memory_order_acquire) * beatFractions[division];
        }
        return brumaClamp(milliseconds * sampleRate / 1000.0f, 1.0f, float(delayL.size() - 2));
    }
    void delay(float& l, float& r) {
        const float samples = delaySamples();
        size_t whole = size_t(samples);
        float frac = samples - float(whole);
        size_t read = (delayIndex + delayL.size() - whole) % delayL.size();
        size_t read2 = (read + delayL.size() - 1) % delayL.size();
        float tapL = delayL[read] * (1.0f - frac) + delayL[read2] * frac;
        float tapR = delayR[read] * (1.0f - frac) + delayR[read2] * frac;
        const float feedback = brumaClamp(step(BrumaDelayFeedback) * 0.01f, 0.0f, 0.94f);
        const int mode = int(step(BrumaDelayMode) + 0.5f);
        float pingPong = mode == 1 ? 1.0f : unit(step(BrumaDelayPingPong));
        const float color = delayColorAlpha;
        const float wet = unit(step(BrumaDelayMix));
        float width = widthUnit(step(BrumaDelayWidth));
        if (mode == 2) { pingPong = 0.0f; width = 0.0f; } // dual mono
        if (mode == 3) { pingPong = std::max(pingPong, 0.5f); width = std::max(width, 1.25f); } // wide
        delayToneL += color * (tapL - delayToneL); delayToneR += color * (tapR - delayToneR);
        delayHighPassL += delayHighPassAlpha * (delayToneL - delayHighPassL);
        delayHighPassR += delayHighPassAlpha * (delayToneR - delayHighPassR);
        const float coloredL = delayToneL - delayHighPassL;
        const float coloredR = delayToneR - delayHighPassR;
        const float feedbackL = coloredL * (1.0f - pingPong) + coloredR * pingPong;
        const float feedbackR = coloredR * (1.0f - pingPong) + coloredL * pingPong;
        delayL[delayIndex] = finite(l + feedbackL * feedback);
        delayR[delayIndex] = finite(r + feedbackR * feedback);
        delayIndex = (delayIndex + 1) % delayL.size();
        float mid = (coloredL + coloredR) * 0.5f, side = (coloredL - coloredR) * 0.5f * width;
        const float duckAmount = unit(step(BrumaDelayDucking));
        const float inputLevel = std::max(std::abs(l), std::abs(r));
        const float duckCoeff = inputLevel > delayDuckEnvelope ? delayDuckAttackAlpha : delayDuckReleaseAlpha;
        delayDuckEnvelope += duckCoeff * (inputLevel - delayDuckEnvelope);
        const float duckGain = 1.0f - duckAmount * std::min(0.85f, delayDuckEnvelope * 2.0f);
        const float wetL = mode == 2 ? coloredL : mid + side;
        const float wetR = mode == 2 ? coloredR : mid - side;
        l += (wetL * duckGain - l) * wet;
        r += (wetR * duckGain - r) * wet;
    }

    void resetReverse() {
        reverseIndex = reverseValidSamples = 0;
        reverseActive = false;
        reverseInputLowL = reverseInputLowR = reverseInputHighL = reverseInputHighR = 0.0f;
        reverseDuckEnvelope = 0.0f;
        reverseCached.fill(-1000.0f);
    }

    void updateReverseCoefficients() {
        if (step(BrumaReverbType) < 5.5f) return;
        const float values[10] = {step(BrumaReverseTime), step(BrumaReverseCurve), step(BrumaReverseDensity),
            step(BrumaReverseLiveness), step(BrumaReverseEndFade), step(BrumaReverseLevel),
            step(BrumaRoom), step(BrumaReverbPredelay), step(BrumaReverbDiffusion),
            step(BrumaReverbHighCut)};
        bool changed = false;
        for (size_t i = 0; i < reverseCached.size(); ++i) changed |= reverseCached[i] != values[i];
        if (!changed) return;
        std::copy(std::begin(values), std::end(values), reverseCached.begin());
        const float duration = values[0] * sampleRate * 0.001f;
        const float predelay = values[7] * sampleRate * 0.001f;
        const float curve = 0.4f + unit(values[1]) * 3.6f;
        const float roomExponent = 0.7f + unit(values[6]) * 0.7f;
        const float live = values[3] * 0.1f;
        const float endFade = std::min(duration * 0.5f, values[4] * sampleRate * 0.001f);
        reverseTapCount = 16 + size_t(unit(values[2]) * 80.0f);
        reverseSpread = unit(values[8]) * sampleRate * 0.0025f;
        reverseEnd = predelay + duration;
        float sumAbs = 0.0f, sumPower = 0.0f;
        uint32_t random = 0x52455850;
        for (size_t i = 0; i < reverseTapCount; ++i) {
            random = random * 1664525u + 1013904223u;
            const float jitter = (float((random >> 8) & 65535) / 65535.0f - 0.5f) * 0.65f;
            const float phase = brumaClamp((float(i) + jitter) / float(reverseTapCount - 1), 0.0f, 1.0f);
            const float fraction = 0.02f + 0.98f * std::pow(phase, roomExponent);
            const float position = duration * fraction;
            const float edge = brumaClamp((duration - position) / std::max(1.0f, endFade), 0.0f, 1.0f);
            const float fade = 0.5f - 0.5f * std::cos(float(M_PI) * edge);
            const float amplitude = (0.02f + live * 0.10f + std::pow(fraction, curve)) * fade;
            reverseDelaysL[i] = predelay + position;
            const float stereoJitter = (float((random >> 24) & 255) / 255.0f - 0.5f) * duration * 0.012f;
            reverseDelaysR[i] = brumaClamp(predelay + position + stereoJitter, predelay + 1, reverseEnd);
            reverseWeightsL[i] = ((random & (1u << 19)) ? -1.0f : 1.0f) * amplitude;
            reverseWeightsR[i] = ((random & (1u << 23)) ? -1.0f : 1.0f) * amplitude;
            sumAbs += amplitude;
            sumPower += amplitude * amplitude;
        }
        // Bounded FIR gain: no recursive return and no self-amplifying loop.
        const float norm = std::min(0.85f / std::sqrt(std::max(1e-9f, sumPower)), 3.0f / std::max(1e-9f, sumAbs));
        for (size_t i = 0; i < reverseTapCount; ++i) {
            reverseWeightsL[i] *= norm; reverseWeightsR[i] *= norm;
        }
        reverseGain = dbToLinear(values[5]) * (0.55f + live * 0.45f);
        reverseHighAlpha = onePole(brumaClamp(values[9], 2000, sampleRate * 0.48f), sampleRate);
    }

    void reverseReverb(float& l, float& r) {
        if (!reverseActive) {
            resetReverse(); reverseActive = true;
            updateReverseCoefficients();
        }
        reverseInputLowL += reverbLowAlpha * (l - reverseInputLowL);
        reverseInputLowR += reverbLowAlpha * (r - reverseInputLowR);
        reverseInputHighL += reverseHighAlpha * (l - reverseInputLowL - reverseInputHighL);
        reverseInputHighR += reverseHighAlpha * (r - reverseInputLowR - reverseInputHighR);
        reverseL[reverseIndex] = finite(reverseInputHighL);
        reverseR[reverseIndex] = finite(reverseInputHighR);
        reverseValidSamples = std::min(reverseValidSamples + 1, reverseL.size());
        const auto read = [&](const std::vector<float>& line, float delay) {
            const float bounded = brumaClamp(delay, 1.0f, float(line.size() - 2));
            const size_t whole = size_t(bounded);
            if (whole >= reverseValidSamples) return 0.0f;
            const size_t a = reverseIndex >= whole ? reverseIndex - whole : reverseIndex + line.size() - whole;
            const size_t b = a == 0 ? line.size() - 1 : a - 1;
            const float fraction = bounded - float(whole);
            const float older = whole + 1 >= reverseValidSamples ? 0.0f : line[b];
            return line[a] * (1 - fraction) + older * fraction;
        };
        const auto reflection = [&](const std::vector<float>& line, float delay) {
            return read(line, delay) * 0.6f
                + read(line, std::min(reverseEnd, delay + reverseSpread)) * 0.25f
                + read(line, std::min(reverseEnd, delay + reverseSpread * 1.73f)) * 0.15f;
        };
        float wetL = 0, wetR = 0;
        for (size_t i = 0; i < reverseTapCount; ++i) {
            const float a = reflection(reverseL, reverseDelaysL[i]);
            const float b = reflection(reverseR, reverseDelaysR[i]);
            wetL += (a * 0.85f + b * 0.15f) * reverseWeightsL[i];
            wetR += (b * 0.85f + a * 0.15f) * reverseWeightsR[i];
        }
        if (++reverseIndex == reverseL.size()) reverseIndex = 0;
        stereoStage(wetL, wetR, widthUnit(step(BrumaReverbWidth)));
        const float inputLevel = std::max(std::abs(l), std::abs(r));
        const float alpha = inputLevel > reverseDuckEnvelope ? reverbDuckAttackAlpha : reverbDuckReleaseAlpha;
        reverseDuckEnvelope += alpha * (inputLevel - reverseDuckEnvelope);
        const float gain = reverseGain * (1 - unit(step(BrumaReverbDucking)) * std::min(0.85f, reverseDuckEnvelope * 2.2f));
        const float wet = unit(step(BrumaReverbMix));
        l = l * (1 - wet) + wetL * gain * wet;
        r = r * (1 - wet) + wetR * gain * wet;
    }

    void reverb(float& l, float& r, const BrumaIRBank& bank) {
        if (step(BrumaReverbType) >= 5.5f) { reverseReverb(l, r); return; }
        reverseActive = false;
        float size = unit(step(BrumaRoom));
        float damping = unit(step(BrumaReverbDamping));
        float preMs = brumaClamp(step(BrumaReverbPredelay), 0.0f, 300.0f);
        float diffusion = unit(step(BrumaReverbDiffusion));
        float earlyLate = unit(step(BrumaReverbEarlyLate));
        float modRate = brumaClamp(step(BrumaReverbModRate), 0.05f, 8.0f);
        float modDepth = unit(step(BrumaReverbModDepth));
        float width = widthUnit(step(BrumaReverbWidth));
        float duck = unit(step(BrumaReverbDucking));
        bool freeze = step(BrumaReverbFreeze) >= 0.5f;
        float irBlend = unit(step(BrumaReverbIRBlend));
        float shimmer = unit(step(BrumaReverbShimmer));
        float mode = step(BrumaReverbType);

        const size_t preCapacity = reverbPredelayL.size();
        size_t preSamples = std::min(preCapacity - 1, size_t(preMs * sampleRate / 1000.0f));
        size_t preRead = (predelayIndex + preCapacity - preSamples) % preCapacity;
        float preL = preSamples == 0 ? l : reverbPredelayL[preRead];
        float preR = preSamples == 0 ? r : reverbPredelayR[preRead];
        reverbPredelayL[predelayIndex] = l; reverbPredelayR[predelayIndex] = r;
        predelayIndex = (predelayIndex + 1) % preCapacity;

        float irL = 0.0f, irR = 0.0f;
        if (bank.partitionCount > 0 && irBlend > 0.001f) {
            if (!irConvolutionActive) convolver.reset();
            irConvolutionActive = true;
            convolver.render(preL, preR, bank, irL, irR);
            irL *= irBlend;
            irR *= irBlend;
        } else if (irConvolutionActive) {
            convolver.reset();
            irConvolutionActive = false;
        }

        reverbPhase += 2.0 * M_PI * modRate / sampleRate;
        if (reverbPhase > 2.0 * M_PI) reverbPhase -= 2.0 * M_PI;
        float mod = std::sin(float(reverbPhase)) * modDepth * 0.0015f * sampleRate;
        float feedbackSum = 0.0f;
        float taps[8];
        float modeScale = mode < 0.5f ? 0.72f : (mode < 1.5f ? 1.25f : (mode < 2.5f ? 0.92f : 0.56f));
        float sizeScale = 0.65f + size * 0.8f;
        for (size_t i = 0; i < reverbLines.size(); ++i) {
            auto& line = reverbLines[i];
            float baseLength = float(line.size() - 8) * (0.57f + float(i) * 0.037f) * modeScale * sizeScale;
            float lengthFloat = brumaClamp(baseLength + (i & 1 ? mod : -mod), 2.0f, float(line.size() - 2));
            size_t length = size_t(lengthFloat);
            float fraction = lengthFloat - float(length);
            size_t readA = (reverbIndices[i] + line.size() - length) % line.size();
            size_t readB = (readA + line.size() - 1) % line.size();
            taps[i] = line[readA] * (1.0f - fraction) + line[readB] * fraction;
            reverbDamping[i] += (0.02f + (1.0f - damping) * 0.82f) * (taps[i] - reverbDamping[i]);
            taps[i] = reverbDamping[i];
            feedbackSum += taps[i];
        }
        float wetInputL = freeze ? 0.0f : preL * (1.0f - earlyLate * 0.45f);
        float wetInputR = freeze ? 0.0f : preR * (1.0f - earlyLate * 0.45f);
        if (mode >= 3.5f && mode < 4.5f) shimmer = std::max(shimmer, 0.18f);
        // Keep shifted energy parallel and quiet; attenuate the FDN loop as
        // shimmer rises to prevent a narrow, self-amplifying pitch tone.
        float gain = freeze ? (shimmer > 0.001f ? 0.995f : 1.0f)
                            : reverbFeedbackGain * (1.0f - 0.12f * shimmer);
        float tailL = (taps[0] + taps[2] + taps[4] + taps[6]) * 0.5f;
        float tailR = (taps[1] + taps[3] + taps[5] + taps[7]) * 0.5f;
        float shiftedL = 0.0f, shiftedR = 0.0f;
        if (shimmer > 0.01f) pitchShiftTail(tailL, tailR, shiftedL, shiftedR);
        for (size_t i = 0; i < reverbLines.size(); ++i) {
            auto& line = reverbLines[i];
            float householder = taps[i] - 0.25f * feedbackSum;
            float input = (i & 1) ? wetInputR : wetInputL;
            // Blend direct and orthogonal feedback paths convexly. The prior
            // additive diffusion term increased loop gain above unity.
            float feedback = taps[i] * (1.0f - diffusion) + householder * diffusion;
            float diffuseInput = input * 0.353553f;
            float shimmerFeed = (i & 1) ? shiftedR : shiftedL;
            float shimmerFeedback = freeze ? 0.0f : shimmerFeed * shimmer * 0.018f;
            line[reverbIndices[i]] = finite(diffuseInput + feedback * gain + shimmerFeedback);
            reverbIndices[i] = (reverbIndices[i] + 1) % line.size();
        }
        float algorithmicL = tailL + wetInputL * 0.18f;
        float algorithmicR = tailR + wetInputR * 0.18f;
        float earlyGain = 1.0f - earlyLate;
        float lateGain = 0.45f + earlyLate * 0.75f;
        float wetL = algorithmicL * lateGain + irL * earlyGain;
        float wetR = algorithmicR * lateGain + irR * earlyGain;
        // Spring mode adds a restrained resonant character.
        if (mode >= 2.5f && mode < 3.5f) {
            wetL += std::sin(float(reverbPhase) * 1.97f) * tailL * 0.12f;
            wetR += std::sin(float(reverbPhase) * 2.03f) * tailR * 0.12f;
        }
        if (shimmer > 0.01f) {
            wetL += shiftedL * shimmer * 0.18f;
            wetR += shiftedR * shimmer * 0.18f;
        }

        // Low/high damping around the effect return.
        float lowA = reverbLowAlpha;
        float highA = reverbHighAlpha;
        reverbLowL += lowA * (wetL - reverbLowL); reverbLowR += lowA * (wetR - reverbLowR);
        float highPassedL = wetL - reverbLowL, highPassedR = wetR - reverbLowR;
        reverbHighL += highA * (highPassedL - reverbHighL);
        reverbHighR += highA * (highPassedR - reverbHighR);
        wetL = reverbHighL;
        wetR = reverbHighR;
        const float inputLevel = std::max(std::abs(l), std::abs(r));
        const float duckCoeff = inputLevel > reverbDuckEnvelope ? reverbDuckAttackAlpha : reverbDuckReleaseAlpha;
        reverbDuckEnvelope += duckCoeff * (inputLevel - reverbDuckEnvelope);
        const float duckGain = 1.0f - duck * std::min(0.85f, reverbDuckEnvelope * 2.2f);
        float mid = (wetL + wetR) * 0.5f, side = (wetL - wetR) * 0.5f * width;
        wetL = (mid + side) * duckGain;
        wetR = (mid - side) * duckGain;
        const float wet = unit(step(BrumaReverbMix));
        l = l * (1.0f - wet) + wetL * wet;
        r = r * (1.0f - wet) + wetR * wet;
    }

    void pitchShiftTail(float inputL, float inputR, float& outputL, float& outputR) {
        const float window = shimmerWindowSamples;
        shimmerLineL[shimmerWriteIndex] = inputL;
        shimmerLineR[shimmerWriteIndex] = inputR;
        shimmerPhase += shimmerPhaseIncrement;
        if (shimmerPhase >= 1.0f) shimmerPhase -= std::floor(shimmerPhase);
        const float phaseA = shimmerPhase;
        const float phaseB = phaseA < 0.5f ? phaseA + 0.5f : phaseA - 0.5f;
        const float delayA = (1.0f - phaseA) * window + 1.0f;
        const float delayB = (1.0f - phaseB) * window + 1.0f;
        const float weightA = 0.5f - 0.5f * std::cos(2.0f * float(M_PI) * phaseA);
        const float weightB = 0.5f - 0.5f * std::cos(2.0f * float(M_PI) * phaseB);
        auto read = [&](const std::vector<float>& line, float delay) {
            const float bounded = brumaClamp(delay, 1.0f, float(line.size() - 2));
            const size_t whole = size_t(bounded);
            const float fraction = bounded - float(whole);
            const size_t a = (shimmerWriteIndex + line.size() - whole) % line.size();
            const size_t b = (a + line.size() - 1) % line.size();
            return line[a] * (1.0f - fraction) + line[b] * fraction;
        };
        const float normalization = std::max(0.001f, weightA + weightB);
        outputL = (read(shimmerLineL, delayA) * weightA + read(shimmerLineL, delayB) * weightB) / normalization;
        outputR = (read(shimmerLineR, delayA) * weightA + read(shimmerLineR, delayB) * weightB) / normalization;
        shimmerWriteIndex = (shimmerWriteIndex + 1) % shimmerLineL.size();
    }

    float stepSafe(AUParameterAddress p) { return step(p); }

    std::array<std::atomic<float>, BrumaParameterCount> targets;
    std::array<std::atomic<float>, BrumaParameterCount> parameterValues;
    std::array<float, BrumaParameterCount> observed{};
    std::array<float, BrumaParameterCount> current{};
    std::array<float, BrumaParameterCount> goal{};
    std::array<float, BrumaParameterCount> slope{};
    std::array<AUAudioFrameCount, BrumaParameterCount> remaining{};
    std::array<std::vector<float>, 8> reverbLines;
    std::array<size_t, 8> reverbIndices{};
    std::array<float, 8> reverbDamping{};
    BrumaPartitionedConvolver convolver;
    std::array<BrumaIRBank, 3> irBanks;
    BrumaIRBank emptyIRBank;
    std::mutex irWriterMutex;
    std::array<std::atomic<uint32_t>, 3> irReaders{};
    std::atomic<int> activeIR{0};
    std::atomic<float> tempo{120.0f};
    std::atomic<float> inputPeak{0.0f}, outputPeak{0.0f};
    std::atomic<bool> bypassed{false};
    std::vector<float> delayL, delayR, modulationL, modulationR, reverbPredelayL, reverbPredelayR;
    std::vector<float> reverseL, reverseR;
    std::array<float, 96> reverseDelaysL{}, reverseDelaysR{}, reverseWeightsL{}, reverseWeightsR{};
    std::array<float, 10> reverseCached{};
    size_t reverseIndex = 0, reverseValidSamples = 0, reverseTapCount = 16;
    bool reverseActive = false;
    float reverseSpread = 0, reverseEnd = 1, reverseGain = 1, reverseHighAlpha = 0.5f;
    float reverseInputLowL = 0, reverseInputLowR = 0, reverseInputHighL = 0, reverseInputHighR = 0, reverseDuckEnvelope = 0;
    std::vector<float> shimmerLineL, shimmerLineR;
    size_t delayIndex = 0, modulationIndex = 0, predelayIndex = 0;
    size_t shimmerWriteIndex = 0;
    int convolverBank = -1;
    bool irConvolutionActive = false;
    float sampleRate = 44100.0f;
    int channels = 2;
    Biquad eqMidL, eqMidR;
    float eqMidB0 = 1, eqMidB1 = 0, eqMidB2 = 0, eqMidA1 = 0, eqMidA2 = 0;
    float eqLowL = 0, eqLowR = 0, eqHighL = 0, eqHighR = 0;
    float eqLowGain = 1, eqHighGain = 1, eqLowAlpha = 0.02f, eqHighAlpha = 0.5f;
    float drivePreviousL = 0, drivePreviousR = 0, driveToneL = 0, driveToneR = 0;
    float driveScreamerLowL = 0, driveScreamerLowR = 0, driveScreamerMidL = 0, driveScreamerMidR = 0;
    float driveScreamerLowAlpha = 0.01f, driveScreamerMidAlpha = 0.08f;
    float driveGain = 1.0f, driveNormalization = 1.0f, driveToneAlpha = 1.0f, driveBias = 0.0f;
    int driveCurveKind = 0;
    float delayColorAlpha = 1.0f, delayHighPassAlpha = 0.01f, delayHighPassL = 0, delayHighPassR = 0;
    float delayDuckEnvelope = 0, delayDuckAttackAlpha = 0.01f, delayDuckReleaseAlpha = 0.001f;
    float reverbDuckEnvelope = 0, reverbDuckAttackAlpha = 0.005f, reverbDuckReleaseAlpha = 0.0005f;
    float reverbFeedbackGain = 0.9f, reverbLowAlpha = 0.1f, reverbHighAlpha = 0.9f;
    float compressorEnvelope = 0, compressorEnvelopeDB = -120.0f;
    float compressorThresholdCached = -18.0f, compressorRatioCached = 3.0f;
    float compressorAttackAlpha = 0.5f, compressorReleaseAlpha = 0.05f, compressorMakeup = 1.0f;
    float compressorTapeAlpha = 0.5f, compressorTapeLowL = 0, compressorTapeLowR = 0;
    float delayToneL = 0, delayToneR = 0;
    float reverbLowL = 0, reverbLowR = 0, reverbHighL = 0, reverbHighR = 0;
    double modPhase = 0, reverbPhase = 0;
    float shimmerPhase = 0.0f;
    float shimmerWindowSamples = 5292.0f, shimmerPhaseIncrement = 0.00019f;
    AUAudioFrameCount dezipperSamples = 512;
    AudioBufferList* inBufferListPtr = nullptr;
    AudioBufferList* outBufferListPtr = nullptr;
};

#endif
