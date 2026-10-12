#ifndef BrumaPartitionedConvolver_hpp
#define BrumaPartitionedConvolver_hpp

#include <array>
#include <algorithm>
#include <cmath>
#include <complex>
#include <cstddef>
#include <vector>

static constexpr size_t BrumaIRBlockSize = 128;
static constexpr size_t BrumaIRFFTSize = BrumaIRBlockSize * 2;
static constexpr size_t BrumaIRCapacity = 32768;
static constexpr size_t BrumaIRPartitionCapacity = BrumaIRCapacity / BrumaIRBlockSize;

struct BrumaIRBank {
    std::vector<std::complex<float>> spectrumL;
    std::vector<std::complex<float>> spectrumR;
    std::array<float, BrumaIRBlockSize> firstL{}, firstR{};
    size_t sampleCount = 0;
    size_t partitionCount = 0;
};

// Uniform overlap-add convolution. IR spectra are prepared on the loading
// thread; render() uses fixed arrays and caller-owned, preallocated history.
class BrumaPartitionedConvolver {
public:
    using Spectrum = std::array<std::complex<float>, BrumaIRFFTSize>;

    void init() {
        historyL.assign(BrumaIRPartitionCapacity * BrumaIRFFTSize, {});
        historyR.assign(BrumaIRPartitionCapacity * BrumaIRFFTSize, {});
        reset();
        for (size_t k = 0; k < BrumaIRFFTSize / 2; ++k) {
            const float angle = -2.0f * float(M_PI) * float(k) / float(BrumaIRFFTSize);
            twiddles[k] = std::complex<float>(std::cos(angle), std::sin(angle));
        }
    }

    void prepare(BrumaIRBank& bank, const float* left, const float* right, size_t count) {
        bank.sampleCount = count;
        bank.partitionCount = (count + BrumaIRBlockSize - 1) / BrumaIRBlockSize;
        bank.spectrumL.assign(bank.partitionCount * BrumaIRFFTSize, {});
        bank.spectrumR.assign(bank.partitionCount * BrumaIRFFTSize, {});
        bank.firstL.fill(0.0f);
        bank.firstR.fill(0.0f);
        for (size_t partition = 0; partition < bank.partitionCount; ++partition) {
            Spectrum blockL{}, blockR{};
            const size_t offset = partition * BrumaIRBlockSize;
            const size_t length = std::min(BrumaIRBlockSize, count - offset);
            for (size_t i = 0; i < length; ++i) {
                blockL[i] = left[offset + i];
                blockR[i] = right ? right[offset + i] : left[offset + i];
                if (partition == 0) {
                    bank.firstL[i] = blockL[i].real();
                    bank.firstR[i] = blockR[i].real();
                }
            }
            transform(blockL, false);
            transform(blockR, false);
            std::copy(blockL.begin(), blockL.end(), bank.spectrumL.begin() + partition * BrumaIRFFTSize);
            std::copy(blockR.begin(), blockR.end(), bank.spectrumR.begin() + partition * BrumaIRFFTSize);
        }
    }

    void reset() {
        // Invalidate spectra instead of clearing a megabyte on an IR change.
        validHistoryBlocks = 0;
        directHistoryL.fill(0.0f);
        directHistoryR.fill(0.0f);
        overlapL.fill(0.0f);
        overlapR.fill(0.0f);
        inputL.fill(0.0f);
        inputR.fill(0.0f);
        tailL.fill(0.0f);
        tailR.fill(0.0f);
        inputIndex = historyIndex = directIndex = 0;
    }

    void render(float inputLeft, float inputRight, const BrumaIRBank& ir, float& outputLeft, float& outputRight) {
        if (inputIndex == 0) prepareTailBlock(ir);
        inputL[inputIndex] = inputLeft;
        inputR[inputIndex] = inputRight;
        directHistoryL[directIndex] = inputLeft;
        directHistoryR[directIndex] = inputRight;
        outputLeft = tailL[inputIndex];
        outputRight = tailR[inputIndex];
        const size_t taps = std::min(ir.sampleCount, BrumaIRBlockSize);
        for (size_t tap = 0; tap < taps; ++tap) {
            const size_t read = (directIndex + BrumaIRBlockSize - tap) % BrumaIRBlockSize;
            outputLeft += ir.firstL[tap] * directHistoryL[read];
            outputRight += ir.firstR[tap] * directHistoryR[read];
        }
        directIndex = (directIndex + 1) % BrumaIRBlockSize;
        ++inputIndex;
        if (inputIndex == BrumaIRBlockSize) {
            storeInputSpectrum();
            inputIndex = 0;
        }
    }

private:
    void transform(Spectrum& values, bool inverse) const {
        for (size_t i = 1, j = 0; i < BrumaIRFFTSize; ++i) {
            size_t bit = BrumaIRFFTSize >> 1;
            for (; j & bit; bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) std::swap(values[i], values[j]);
        }
        for (size_t length = 2; length <= BrumaIRFFTSize; length <<= 1) {
            const size_t half = length >> 1;
            const size_t twiddleStep = BrumaIRFFTSize / length;
            for (size_t base = 0; base < BrumaIRFFTSize; base += length) {
                for (size_t j = 0; j < half; ++j) {
                    auto twiddle = twiddles[j * twiddleStep];
                    if (inverse) twiddle = std::conj(twiddle);
                    const auto even = values[base + j];
                    const auto odd = values[base + j + half] * twiddle;
                    values[base + j] = even + odd;
                    values[base + j + half] = even - odd;
                }
            }
        }
        if (inverse) {
            const float scale = 1.0f / float(BrumaIRFFTSize);
            for (auto& value : values) value *= scale;
        }
    }

    void storeInputSpectrum() {
        Spectrum inputSpectrumL{}, inputSpectrumR{};
        std::copy(inputL.begin(), inputL.end(), inputSpectrumL.begin());
        std::copy(inputR.begin(), inputR.end(), inputSpectrumR.begin());
        transform(inputSpectrumL, false);
        transform(inputSpectrumR, false);
        const size_t ringOffset = historyIndex * BrumaIRFFTSize;
        std::copy(inputSpectrumL.begin(), inputSpectrumL.end(), historyL.begin() + ringOffset);
        std::copy(inputSpectrumR.begin(), inputSpectrumR.end(), historyR.begin() + ringOffset);

        historyIndex = (historyIndex + 1) % BrumaIRPartitionCapacity;
        validHistoryBlocks = std::min(validHistoryBlocks + 1, BrumaIRPartitionCapacity);
    }

    void prepareTailBlock(const BrumaIRBank& ir) {
        Spectrum resultL{}, resultR{};
        for (size_t partition = 1; partition < ir.partitionCount && partition <= validHistoryBlocks; ++partition) {
            size_t historyPartition = (historyIndex + BrumaIRPartitionCapacity - partition) % BrumaIRPartitionCapacity;
            const size_t inputOffset = historyPartition * BrumaIRFFTSize;
            const size_t impulseOffset = partition * BrumaIRFFTSize;
            for (size_t bin = 0; bin < BrumaIRFFTSize; ++bin) {
                resultL[bin] += ir.spectrumL[impulseOffset + bin] * historyL[inputOffset + bin];
                resultR[bin] += ir.spectrumR[impulseOffset + bin] * historyR[inputOffset + bin];
            }
        }
        transform(resultL, true);
        transform(resultR, true);
        for (size_t i = 0; i < BrumaIRBlockSize; ++i) {
            tailL[i] = resultL[i].real() + overlapL[i];
            tailR[i] = resultR[i].real() + overlapR[i];
            overlapL[i] = resultL[i + BrumaIRBlockSize].real();
            overlapR[i] = resultR[i + BrumaIRBlockSize].real();
        }
    }

    std::array<std::complex<float>, BrumaIRFFTSize / 2> twiddles{};
    std::vector<std::complex<float>> historyL, historyR;
    std::array<float, BrumaIRBlockSize> inputL{}, inputR{}, tailL{}, tailR{}, overlapL{}, overlapR{};
    std::array<float, BrumaIRBlockSize> directHistoryL{}, directHistoryR{};
    size_t inputIndex = 0, historyIndex = 0, directIndex = 0;
    size_t validHistoryBlocks = 0;
};

#endif
