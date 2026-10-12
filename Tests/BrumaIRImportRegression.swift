import Foundation
import AudioToolbox
import AVFoundation
import AUv3FilterFramework

var cleanupFixture: (() -> Void)?
func require(_ ok: Bool, _ label: String) { if !ok { cleanupFixture?(); fatalError("FAIL: \(label)") } }
let count = 8192
func convertedSine(_ frequency: Double) throws -> [Float] {
    let signal = (0..<count).map { Float(sin(2 * Double.pi * frequency * Double($0) / 96000)) }
    return try AUv3FilterDemo.resampleImpulseChannel(signal, sourceRate: 96000, targetRate: 48000)
}
func rms(_ samples: [Float]) -> Double {
    let body = samples.dropFirst(128).dropLast(128)
    return sqrt(body.reduce(0.0) { $0 + Double($1 * $1) } / Double(body.count))
}
let passband = rms(try convertedSine(1000))
let stopband = rms(try convertedSine(30000))
require(abs(passband - sqrt(2)) < 0.01, "IR gain scaling and passband preservation")
require(stopband / passband < 0.002, "downsampling rejects frequencies above target Nyquist")
var impulse = [Float](repeating: 0, count: 1024); impulse[256] = 1
for rate in [24000.0, 48000.0, 96000.0] {
    let converted = try AUv3FilterDemo.resampleImpulseChannel(impulse, sourceRate: 48000, targetRate: rate)
    require(abs(converted.reduce(0, +) - 1) < 0.005, "resampled impulse coefficient sum at \(rate)")
}
do {
    _ = try AUv3FilterDemo.resampleImpulseChannel([Float.nan], sourceRate: 48000, targetRate: 44100)
    fatalError("NaN IR accepted")
} catch {}
print(String(format: "PASS: IR resampling, passband RMS %.5f, rejected-band RMS %.8f", passband, stopband))

let fixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent("BrumaIRRegression-" + UUID().uuidString)
try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
var ownedCopies: Set<String> = []
cleanupFixture = {
    for path in ownedCopies { try? FileManager.default.removeItem(atPath: path) }
    try? FileManager.default.removeItem(at: fixtureDir)
}
defer { cleanupFixture?(); cleanupFixture = nil }
let format = AVAudioFormat(standardFormatWithSampleRate: 96000, channels: 1)!
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192000)!
buffer.frameLength = 192000
buffer.floatChannelData![0].initialize(repeating: 0, count: 192000)
buffer.floatChannelData![0][128] = 0.4
let url = fixtureDir.appendingPathComponent("Room Original.wav")
do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
let description = AudioComponentDescription(componentType: kAudioUnitType_Effect,
    componentSubType: 0x42726D61, componentManufacturer: 0x4C74736B, componentFlags: 0, componentFlagsMask: 0)
let unit = try AUv3FilterDemo(componentDescription: description)
func recordCopy() {
    if let path = unit.fullState?["BrumaImpulseResponsePath"] as? String { ownedCopies.insert(path) }
}
try unit.loadImpulseResponse(from: url)
recordCopy()
let metadata = unit.impulseResponseMetadata!
require(metadata.name == "Room Original.wav" && metadata.truncated, "original name and truncation metadata")
require(abs(metadata.usedDuration - 32768 / metadata.sampleRate) < 1e-8 && abs(metadata.sourceDuration - 2) < 1e-8, "bounded effective IR duration")
let state = unit.fullState!
do { try unit.loadImpulseResponse(from: fixtureDir.appendingPathComponent("missing.wav")); fatalError("missing file accepted") } catch {}
require(unit.impulseResponseName == metadata.name, "failed import preserves current IR")
unit.clearImpulseResponse()
unit.fullState = state
require(unit.impulseResponseName == "Room Original.wav", "display name survives state restoration")

var callbacks = 0, successes = 0, cancellations = 0
func completion(_ result: Result<BrumaIRImportMetadata, Error>) {
    require(Thread.isMainThread, "completion delivered on main thread")
    callbacks += 1
    switch result {
    case .success: successes += 1; recordCopy()
    case .failure(let error):
        require((error as NSError).code == NSUserCancelledError, "superseded import is cancellation")
        cancellations += 1
    }
}
unit.loadImpulseResponseAsync(from: url, completion: completion)
unit.loadImpulseResponseAsync(from: url, completion: completion)
let deadline = Date().addingTimeInterval(15)
while callbacks < 2 && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
require(callbacks == 2 && successes == 1 && cancellations == 1, "only latest asynchronous import publishes")
callbacks = 0; successes = 0; cancellations = 0
unit.loadImpulseResponseAsync(from: url, completion: completion)
unit.clearImpulseResponse()
while callbacks < 1 && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
require(callbacks == 1 && cancellations == 1 && unit.impulseResponseMetadata == nil, "clear cancels queued import")
print("PASS: WAV import, truncation, failed-load recovery, state restoration, async supersession and cancellation")

let aiffURL = fixtureDir.appendingPathComponent("Stereo Room.aiff")
let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
let stereo = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 2048)!
stereo.frameLength = 2048
for channel in 0..<2 { stereo.floatChannelData![channel].initialize(repeating: 0, count: 2048) }
stereo.floatChannelData![0][64] = 0.3; stereo.floatChannelData![1][96] = 0.2
let aiffSettings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
    AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true]
do { let file = try AVAudioFile(forWriting: aiffURL, settings: aiffSettings); try file.write(from: stereo) }
try unit.loadImpulseResponse(from: aiffURL)
recordCopy()
require(unit.impulseResponseName == "Stereo Room.aiff" && unit.impulseResponseMetadata?.truncated == false, "stereo AIFF import")
let tinyURL = fixtureDir.appendingPathComponent("Tiny Impulse.wav")
let tiny = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)!
tiny.frameLength = 32; tiny.floatChannelData![0].initialize(repeating: 0, count: 32); tiny.floatChannelData![0][8] = 0.4
do { let file = try AVAudioFile(forWriting: tinyURL, settings: format.settings); try file.write(from: tiny) }
try unit.loadImpulseResponse(from: tinyURL)
recordCopy()
require(unit.impulseResponseMetadata!.usedDuration > 0, "sub-chunk WAV import")
unit.clearImpulseResponse()
print("PASS: stereo AIFF and tiny WAV import")
