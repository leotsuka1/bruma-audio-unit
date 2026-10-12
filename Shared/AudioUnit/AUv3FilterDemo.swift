import AudioToolbox
import AVFoundation
import CoreAudioKit
import Foundation

public struct BrumaUserPreset: Identifiable {
    public let id: String
    public let name: String
    public let number: Int
    fileprivate let state: Data
}

public struct BrumaParameterDisplay {
    public let identifier: String
    public let name: String
    public let address: AUParameterAddress
}

public struct BrumaIRImportMetadata {
    public let name: String
    public let sourceDuration: Double
    public let usedDuration: Double
    public let sampleRate: Double
    public let truncated: Bool
}

public final class AUv3FilterDemo: AUAudioUnit {
    private let kernelAdapter = FilterDSPKernelAdapter()
    private var inputBus: AUAudioUnitBus!
    private var outputBus: AUAudioUnitBus!
    private lazy var inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
    private lazy var outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
    private var tree: AUParameterTree!
    private var _currentPreset: AUAudioUnitPreset?
    private var impulseResponseURL: URL?
    private var missingImpulseName: String?
    private var impulseMetadata: BrumaIRImportMetadata?
    private let impulseQueue = DispatchQueue(label: "Bruma.IR.Import", qos: .userInitiated)
    private let impulseLock = NSLock()
    private var impulseGeneration: UInt64 = 0

    private func withImpulseLock<T>(_ action: () throws -> T) rethrows -> T {
        impulseLock.lock()
        defer { impulseLock.unlock() }
        return try action()
    }
    private func nextImpulseGeneration() -> UInt64 {
        withImpulseLock { impulseGeneration &+= 1; return impulseGeneration }
    }
    weak var viewController: AUv3FilterDemoViewController?

    public override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    public override var outputBusses: AUAudioUnitBusArray { outputBusArray }
    public override var parameterTree: AUParameterTree? { get { tree } set {} }
    public override var channelCapabilities: [NSNumber]? { [2, 2] }
    public override var canProcessInPlace: Bool { true }
    public override var maximumFramesToRender: AUAudioFrameCount {
        get { kernelAdapter.maximumFramesToRender }
        set { kernelAdapter.maximumFramesToRender = newValue }
    }
    public override var shouldBypassEffect: Bool {
        get { kernelAdapter.effectBypass() }
        set { kernelAdapter.setEffectBypass(newValue) }
    }
    public override func reset() {
        kernelAdapter.reset()
        super.reset()
    }
    public override var factoryPresets: [AUAudioUnitPreset] {
        Self.presetNames.enumerated().map { element in
            let preset = AUAudioUnitPreset()
            preset.number = element.offset
            preset.name = element.element
            return preset
        }
    }
    public override var currentPreset: AUAudioUnitPreset? {
        get { _currentPreset }
        set {
            guard let newValue else { return }
            // Hosts may re-assert the currently selected factory preset while
            // reinitializing an AU. Keep the saved parameter values in that
            // case; selecting a different preset still applies its controls.
            if _currentPreset?.number == newValue.number,
               _currentPreset?.name == newValue.name { return }
            _currentPreset = newValue
            if Self.presetValues.indices.contains(newValue.number) {
                applyPreset(newValue.number)
            } else if let savedPreset = brumaUserPresets.first(where: { $0.number == newValue.number }),
                      let state = try? PropertyListSerialization.propertyList(from: savedPreset.state,
                                                                              options: [], format: nil) as? [String: Any] {
                fullState = state
            }
        }
    }
    // GarageBand on macOS 27 currently sends presetStateFor to the remote
    // extension context when this is true; that selector is not implemented
    // by the host proxy and terminates the AU process. Bruma persists its own
    // presets in the extension container and keeps the host API disabled.
    public override var supportsUserPresets: Bool { false }

    public func resetToDefaultPreset() {
        guard let preset = factoryPresets.first else { return }
        _currentPreset = preset
        applyPreset(0)
    }

    private struct StoredUserPreset: Codable {
        let id: String
        let name: String
        let state: Data
        var number: Int?
    }
    private static let snapshotKey = "Bruma.ParameterSnapshot.v1"
    private static let schemaKey = "Bruma.StateSchemaVersion"
    private static let userPresetsKey = "Bruma.LocalUserPresets.v1"

    private var storedUserPresets: [StoredUserPreset] {
        guard let data = UserDefaults.standard.data(forKey: Self.userPresetsKey),
              let presets = try? JSONDecoder().decode([StoredUserPreset].self, from: data) else { return [] }
        var migrated = presets
        if migrated.contains(where: { $0.number == nil }) {
            for index in migrated.indices where migrated[index].number == nil {
                migrated[index].number = -(index + 1)
            }
            if let encoded = try? JSONEncoder().encode(migrated) {
                UserDefaults.standard.set(encoded, forKey: Self.userPresetsKey)
            }
        }
        return migrated
    }

    public var brumaUserPresets: [BrumaUserPreset] {
        storedUserPresets.map { preset in
            BrumaUserPreset(id: preset.id, name: preset.name, number: preset.number ?? -1, state: preset.state)
        }
    }

    @discardableResult
    public func saveBrumaUserPreset(named name: String) throws -> BrumaUserPreset {
        guard let state = fullState else {
            throw NSError(domain: "Bruma.Preset", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No se pudo leer el estado actual de Bruma."])
        }
        let stateData = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
        var presets = storedUserPresets
        let counterKey = "Bruma.LocalUserPresets.NextNumber"
        let next = min(UserDefaults.standard.integer(forKey: counterKey), presets.compactMap(\.number).min() ?? 0) - 1
        let stored = StoredUserPreset(id: UUID().uuidString, name: name, state: stateData, number: next)
        presets.append(stored)
        UserDefaults.standard.set(try JSONEncoder().encode(presets), forKey: Self.userPresetsKey)
        UserDefaults.standard.set(next, forKey: counterKey)
        return BrumaUserPreset(id: stored.id, name: stored.name, number: next, state: stored.state)
    }

    public func loadBrumaUserPreset(_ preset: BrumaUserPreset) {
        guard let index = storedUserPresets.firstIndex(where: { $0.id == preset.id }),
              let state = try? PropertyListSerialization.propertyList(from: storedUserPresets[index].state,
                                                                       options: [], format: nil) as? [String: Any] else { return }
        fullState = state
        let selected = AUAudioUnitPreset()
        selected.number = storedUserPresets[index].number ?? preset.number
        selected.name = storedUserPresets[index].name
        _currentPreset = selected
    }

    public func deleteBrumaUserPreset(_ preset: BrumaUserPreset) {
        var presets = storedUserPresets
        presets.removeAll { $0.id == preset.id }
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Self.userPresetsKey)
        }
        if _currentPreset?.number == preset.number { resetToDefaultPreset() }
    }

    public override var fullState: [String: Any]? {
        get {
            var state = super.fullState ?? [:]
            state[Self.schemaKey] = 1
            state[Self.snapshotKey] = Dictionary<String, AUValue>(uniqueKeysWithValues: Self.definitions.compactMap { definition in
                guard let parameter = tree.parameter(withAddress: definition.address) else { return nil }
                return (definition.id, parameter.value)
            })
            withImpulseLock {
                if let path = impulseResponseURL?.path { state[Self.irPathKey] = path }
                if let missingImpulseName { state[Self.irMissingKey] = missingImpulseName }
                if let name = impulseMetadata?.name { state["BrumaImpulseResponseDisplayName"] = name }
            }
            return state
        }
        set {
            _ = nextImpulseGeneration()
            super.fullState = newValue
            guard let state = newValue else { return }
            if (state[Self.schemaKey] as? Int) == 1,
               let snapshot = state[Self.snapshotKey] as? [String: NSNumber] {
                // Restore old aliases first, then canonical controls. In
                // particular the saved Damping must win over legacy Tone.
                let aliases: Set<AUParameterAddress> = [2, 3, 4]
                let ordered = Self.definitions.filter { aliases.contains($0.address) }
                    + Self.definitions.filter { !aliases.contains($0.address) }
                for definition in ordered {
                    if let value = snapshot[definition.id]?.floatValue, value.isFinite {
                        tree.parameter(withAddress: definition.address)?.setValue(value, originator: nil)
                    }
                }
            }
            if let path = state[Self.irPathKey] as? String {
                let url = URL(fileURLWithPath: path)
                let name = state["BrumaImpulseResponseDisplayName"] as? String ?? url.lastPathComponent
                if FileManager.default.fileExists(atPath: path) { restoreImpulse(from: url, displayName: name) }
                else { discardImpulse(resetBlend: false, missingName: name) }
            } else {
                discardImpulse(resetBlend: false, missingName: state[Self.irMissingKey] as? String)
            }
        }
    }

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        try super.init(componentDescription: componentDescription, options: options)
        inputBus = kernelAdapter.inputBus
        outputBus = kernelAdapter.outputBus
        try inputBus.setFormat(format)
        try outputBus.setFormat(format)
        makeParameterTree()
        _currentPreset = factoryPresets.first
    }

    private struct Definition {
        let id: String
        let name: String
        let address: AUParameterAddress
        let min: AUValue
        let max: AUValue
        let initial: AUValue
        let unit: AudioUnitParameterUnit
        let strings: [String]?
        var canRamp = true
    }

    private static let definitions: [Definition] = [
        .init(id: "mix", name: "Mix", address: 0, min: 0, max: 100, initial: 28, unit: .percent, strings: nil),
        .init(id: "room", name: "Room", address: 1, min: 0, max: 100, initial: 58, unit: .percent, strings: nil),
        .init(id: "tone", name: "Tone", address: 2, min: 0, max: 100, initial: 42, unit: .percent, strings: nil),
        .init(id: "cutoff", name: "Mix (legacy host)", address: 3, min: 0, max: 100, initial: 28, unit: .percent, strings: nil),
        .init(id: "resonance", name: "Room (legacy host)", address: 4, min: 0, max: 100, initial: 58, unit: .percent, strings: nil),
        .init(id: "stereoWidth", name: "Stereo Width", address: 5, min: 0, max: 150, initial: 100, unit: .percent, strings: nil),
        .init(id: "eqBypass", name: "EQ Bypass", address: 6, min: 0, max: 1, initial: 0, unit: .boolean, strings: ["Off", "On"], canRamp: false),
        .init(id: "eqLow", name: "Low Gain", address: 7, min: -18, max: 18, initial: 0, unit: .decibels, strings: nil),
        .init(id: "eqMid", name: "Mid Gain", address: 8, min: -18, max: 18, initial: 0, unit: .decibels, strings: nil),
        .init(id: "eqMidFrequency", name: "Mid Frequency", address: 9, min: 80, max: 12_000, initial: 900, unit: .hertz, strings: nil),
        .init(id: "eqMidQ", name: "Mid Q", address: 52, min: 0.3, max: 5, initial: 1, unit: .generic, strings: nil),
        .init(id: "eqHigh", name: "High Gain", address: 10, min: -18, max: 18, initial: 0, unit: .decibels, strings: nil),
        .init(id: "driveBypass", name: "Drive Bypass", address: 11, min: 0, max: 1, initial: 0, unit: .boolean, strings: ["Off", "On"], canRamp: false),
        .init(id: "driveAmount", name: "Drive", address: 12, min: 0, max: 24, initial: 4, unit: .decibels, strings: nil),
        .init(id: "driveTone", name: "Drive Tone", address: 13, min: 0, max: 100, initial: 50, unit: .percent, strings: nil),
        .init(id: "driveMix", name: "Drive Mix", address: 14, min: 0, max: 100, initial: 100, unit: .percent, strings: nil),
        .init(id: "compressorBypass", name: "Compressor Bypass", address: 15, min: 0, max: 1, initial: 0, unit: .boolean, strings: ["Off", "On"], canRamp: false),
        .init(id: "compressorThreshold", name: "Threshold", address: 16, min: -48, max: 0, initial: -18, unit: .decibels, strings: nil),
        .init(id: "compressorRatio", name: "Ratio", address: 17, min: 1, max: 20, initial: 3, unit: .ratio, strings: nil),
        .init(id: "compressorAttack", name: "Attack", address: 18, min: 0.1, max: 100, initial: 18, unit: .milliseconds, strings: nil),
        .init(id: "compressorRelease", name: "Release", address: 19, min: 10, max: 1000, initial: 180, unit: .milliseconds, strings: nil),
        .init(id: "compressorMakeup", name: "Makeup", address: 20, min: 0, max: 24, initial: 0, unit: .decibels, strings: nil),
        .init(id: "modBypass", name: "Modulation Bypass", address: 21, min: 0, max: 1, initial: 0, unit: .boolean, strings: ["Off", "On"], canRamp: false),
        .init(id: "modType", name: "Modulation Type", address: 22, min: 0, max: 1, initial: 0, unit: .indexed, strings: ["Chorus", "Flanger"], canRamp: false),
        .init(id: "modRate", name: "Rate", address: 23, min: 0.05, max: 8, initial: 0.8, unit: .hertz, strings: nil),
        .init(id: "modDepth", name: "Depth", address: 24, min: 0, max: 100, initial: 45, unit: .percent, strings: nil),
        .init(id: "modFeedback", name: "Feedback", address: 25, min: 0, max: 95, initial: 20, unit: .percent, strings: nil),
        .init(id: "delayBypass", name: "Delay Bypass", address: 26, min: 0, max: 1, initial: 0, unit: .boolean, strings: ["Off", "On"], canRamp: false),
        .init(id: "delayTime", name: "Delay Time", address: 27, min: 1, max: 2000, initial: 420, unit: .milliseconds, strings: nil),
        .init(id: "delaySync", name: "Tempo Sync", address: 28, min: 0, max: 1, initial: 0, unit: .boolean, strings: ["Free", "Sync"], canRamp: false),
        .init(id: "delayDivision", name: "Note Division", address: 29, min: 0, max: 9, initial: 0, unit: .indexed, strings: ["Quarter", "Dotted 8th", "8th", "16th", "Triplet 8th (legacy)", "Dotted 16th", "Triplet 16th (legacy)", "32nd", "Triplet 8th", "Triplet 16th"], canRamp: false),
        .init(id: "delayFeedback", name: "Feedback", address: 30, min: 0, max: 94, initial: 32, unit: .percent, strings: nil),
        .init(id: "delayTone", name: "Delay Tone", address: 31, min: 0, max: 100, initial: 45, unit: .percent, strings: nil),
        .init(id: "delayMix", name: "Delay Mix", address: 32, min: 0, max: 100, initial: 25, unit: .percent, strings: nil),
        .init(id: "delayWidth", name: "Delay Width", address: 33, min: 0, max: 150, initial: 100, unit: .percent, strings: nil),
        .init(id: "reverbBypass", name: "Reverb Bypass", address: 34, min: 0, max: 1, initial: 0, unit: .boolean, strings: ["Off", "On"], canRamp: false),
        .init(id: "reverbType", name: "Reverb Type", address: 35, min: 0, max: 6, initial: 1, unit: .indexed, strings: ["Room", "Hall", "Plate", "Spring", "Shimmer", "IR Hybrid", "Reverse Gate"], canRamp: false),
        .init(id: "reverbDecay", name: "Decay", address: 36, min: 0.1, max: 30, initial: 2.8, unit: .seconds, strings: nil),
        .init(id: "reverbPredelay", name: "Pre-delay", address: 37, min: 0, max: 300, initial: 24, unit: .milliseconds, strings: nil),
        .init(id: "reverbDiffusion", name: "Diffusion", address: 38, min: 0, max: 100, initial: 78, unit: .percent, strings: nil),
        .init(id: "reverbEarlyLate", name: "Early / Late", address: 39, min: 0, max: 100, initial: 50, unit: .percent, strings: nil),
        .init(id: "reverbDamping", name: "Damping", address: 40, min: 0, max: 100, initial: 42, unit: .percent, strings: nil),
        .init(id: "reverbLowCut", name: "Low Cut", address: 41, min: 20, max: 1000, initial: 80, unit: .hertz, strings: nil),
        .init(id: "reverbHighCut", name: "High Cut", address: 42, min: 2000, max: 20_000, initial: 16_500, unit: .hertz, strings: nil),
        .init(id: "reverbModRate", name: "Modulation Rate", address: 43, min: 0.05, max: 8, initial: 0.25, unit: .hertz, strings: nil),
        .init(id: "reverbModDepth", name: "Modulation Depth", address: 44, min: 0, max: 100, initial: 18, unit: .percent, strings: nil),
        .init(id: "reverbWidth", name: "Reverb Width", address: 45, min: 0, max: 150, initial: 100, unit: .percent, strings: nil),
        .init(id: "reverbDucking", name: "Ducking", address: 46, min: 0, max: 100, initial: 8, unit: .percent, strings: nil),
        .init(id: "reverbFreeze", name: "Freeze", address: 47, min: 0, max: 1, initial: 0, unit: .boolean, strings: ["Off", "On"], canRamp: false),
        .init(id: "reverbIRBlend", name: "IR Blend", address: 48, min: 0, max: 100, initial: 0, unit: .percent, strings: nil),
        .init(id: "reverbShimmer", name: "Shimmer", address: 49, min: 0, max: 100, initial: 0, unit: .percent, strings: nil),
        .init(id: "outputGain", name: "Output Gain", address: 50, min: -24, max: 12, initial: 0, unit: .decibels, strings: nil),
        .init(id: "reverbMix", name: "Reverb Mix", address: 51, min: 0, max: 100, initial: 100, unit: .percent, strings: nil),
        .init(id: "shimmerPitch", name: "Shimmer Pitch (st)", address: 53, min: 7, max: 24, initial: 12, unit: .generic, strings: nil)
        ,.init(id: "driveCharacter", name: "Drive Character", address: 54, min: 0, max: 7, initial: 0, unit: .indexed, strings: ["Smooth", "Tube", "Tape", "Dense", "Console", "Screamer", "Transparent OD", "Fuzz"], canRamp: false)
        ,.init(id: "compressorKnee", name: "Soft Knee", address: 55, min: 0, max: 18, initial: 6, unit: .decibels, strings: nil)
        ,.init(id: "delayPingPong", name: "Ping Pong", address: 56, min: 0, max: 100, initial: 0, unit: .percent, strings: nil)
        ,.init(id: "delayMode", name: "Stereo Mode", address: 57, min: 0, max: 3, initial: 0, unit: .indexed, strings: ["Stereo", "Ping-Pong", "Dual Mono", "Wide"], canRamp: false)
        ,.init(id: "delayLowCut", name: "Low Cut", address: 58, min: 20, max: 1000, initial: 60, unit: .hertz, strings: nil)
        ,.init(id: "delayHighCut", name: "High Cut", address: 59, min: 2000, max: 20_000, initial: 15_000, unit: .hertz, strings: nil)
        ,.init(id: "delayDucking", name: "Ducking", address: 60, min: 0, max: 100, initial: 0, unit: .percent, strings: nil)
        ,.init(id: "compressorModel", name: "Compressor Model", address: 61, min: 0, max: 4, initial: 0, unit: .indexed, strings: ["Clean Peak", "VCA RMS", "FET", "Opto", "Reel-to-Reel"], canRamp: false)
        ,.init(id: "compressorTapeAmount", name: "Tape Color", address: 62, min: 0, max: 100, initial: 32, unit: .percent, strings: nil)
        ,.init(id: "compressorTapeSpeed", name: "Tape Speed", address: 63, min: 0, max: 2, initial: 1, unit: .indexed, strings: ["7.5 ips", "15 ips", "30 ips"], canRamp: false)
        ,.init(id: "reverseTime", name: "Reverse Duration", address: 64, min: 50, max: 2000, initial: 450, unit: .milliseconds, strings: nil)
        ,.init(id: "reverseCurve", name: "Rise Curve", address: 65, min: 0, max: 100, initial: 70, unit: .percent, strings: nil)
        ,.init(id: "reverseDensity", name: "Reflection Density", address: 66, min: 0, max: 100, initial: 75, unit: .percent, strings: nil)
        ,.init(id: "reverseLiveness", name: "Liveness", address: 67, min: 0, max: 10, initial: 5, unit: .generic, strings: nil)
        ,.init(id: "reverseEndFade", name: "Gate End Fade", address: 68, min: 1, max: 250, initial: 12, unit: .milliseconds, strings: nil)
        ,.init(id: "reverseLevel", name: "Reverse Level", address: 69, min: -12, max: 12, initial: 0, unit: .decibels, strings: nil)
    ]

    private static let presetNames = [
        "Niebla suave", "Sala íntima", "Hall cinematográfico", "Plate vocal",
        "Spring vintage", "Shimmer nube", "Delay rítmico", "Drum glue",
        "Coro ancho", "Lo-fi cálido", "Espacio limpio", "IR natural",
        "Voz de estudio", "Piano bloom", "Room de batería", "Swell ambiental",
        "Plate de guitarra", "Cassette suave", "Tube Screamer Lead", "Reel-to-Reel Glue", "Wide Dotted Echo",
        "Reverse Vintage", "Reverse Shoegaze", "Reverse Percussion"
    ]
    public static var presetDisplayNames: [String] { presetNames }
    public static var displayParameters: [BrumaParameterDisplay] {
        definitions.map { BrumaParameterDisplay(identifier: $0.id, name: $0.name, address: $0.address) }
    }
    public static func address(for identifier: String) -> AUParameterAddress {
        definitions.first(where: { $0.id == identifier })?.address ?? 0
    }
    private static let presetValues: [[String: AUValue]] = [
        [:],
        ["room": 28, "reverbType": 0, "reverbDecay": 0.8, "reverbPredelay": 12, "reverbMix": 70],
        ["room": 82, "reverbType": 1, "reverbDecay": 8.5, "reverbPredelay": 42, "reverbMix": 86, "reverbWidth": 130],
        ["room": 62, "reverbType": 2, "reverbDecay": 3.2, "reverbPredelay": 28, "reverbMix": 75],
        ["room": 64, "reverbType": 3, "reverbDecay": 1.8, "reverbDiffusion": 52, "reverbMix": 70],
        ["room": 88, "reverbType": 4, "reverbDecay": 12, "reverbShimmer": 58, "reverbMix": 78],
        ["delaySync": 1, "delayDivision": 1, "delayFeedback": 48, "delayMix": 35, "reverbMix": 18],
        ["compressorThreshold": -24, "compressorRatio": 5, "compressorAttack": 8, "compressorRelease": 95, "driveAmount": 3, "driveMix": 35],
        ["modDepth": 70, "modRate": 0.35, "stereoWidth": 140, "reverbMix": 20],
        ["driveAmount": 13, "driveTone": 35, "driveMix": 62, "eqHigh": -4, "reverbMix": 18],
        ["mix": 0, "reverbMix": 0, "driveBypass": 1, "compressorBypass": 1, "modBypass": 1, "delayBypass": 1, "reverbBypass": 1],
        ["reverbType": 5, "reverbIRBlend": 60, "reverbDecay": 2.3, "reverbMix": 70],
        ["reverbType": 2, "reverbDecay": 1.7, "reverbPredelay": 34, "reverbHighCut": 14_000, "reverbMix": 28, "compressorThreshold": -25, "compressorRatio": 2.4, "compressorAttack": 12, "compressorRelease": 115],
        ["reverbType": 1, "reverbDecay": 5.2, "reverbPredelay": 22, "reverbDiffusion": 90, "reverbWidth": 128, "reverbMix": 33],
        ["room": 35, "reverbType": 0, "reverbDecay": 0.55, "reverbPredelay": 8, "reverbEarlyLate": 30, "reverbMix": 24, "compressorThreshold": -22, "compressorRatio": 4.5, "compressorAttack": 22, "compressorRelease": 90],
        ["reverbType": 1, "reverbDecay": 18, "reverbPredelay": 64, "reverbDiffusion": 96, "reverbModDepth": 32, "reverbWidth": 145, "reverbMix": 58, "delayBypass": 1],
        ["reverbType": 2, "reverbDecay": 2.8, "reverbPredelay": 25, "reverbMix": 30, "modType": 1, "modRate": 0.28, "modDepth": 22, "modFeedback": 12],
        ["driveAmount": 6, "driveTone": 38, "driveMix": 32, "driveCharacter": 2, "eqMid": -2, "eqHigh": -3, "reverbType": 0, "reverbDecay": 1.1, "reverbMix": 15, "stereoWidth": 82],
        ["driveCharacter": 5, "driveAmount": 13, "driveTone": 58, "driveMix": 74, "eqLow": -2, "eqMid": 3, "compressorThreshold": -23, "compressorRatio": 3.5, "compressorAttack": 14, "compressorRelease": 110],
        ["compressorModel": 4, "compressorTapeAmount": 38, "compressorTapeSpeed": 1, "compressorThreshold": -18, "compressorRatio": 2.5, "compressorKnee": 9, "compressorAttack": 24, "compressorRelease": 220, "compressorMakeup": 2, "driveCharacter": 2, "driveAmount": 4, "driveMix": 28],
        ["delaySync": 1, "delayMode": 3, "delayDivision": 1, "delayFeedback": 38, "delayLowCut": 140, "delayHighCut": 8500, "delayDucking": 28, "delayMix": 32, "delayWidth": 140, "reverbMix": 18],
        ["mix": 100, "eqBypass": 1, "driveBypass": 1, "compressorBypass": 1, "modBypass": 1, "delayBypass": 1, "reverbType": 6, "reverseTime": 350, "reverseCurve": 65, "reverseDensity": 65, "reverseLiveness": 5, "reverseEndFade": 12, "reverbPredelay": 5, "reverbHighCut": 6300, "reverbMix": 55],
        ["mix": 100, "eqBypass": 1, "driveBypass": 0, "driveCharacter": 5, "driveAmount": 8, "driveMix": 50, "compressorBypass": 1, "modBypass": 1, "delayBypass": 1, "reverbType": 6, "reverseTime": 650, "reverseCurve": 85, "reverseDensity": 100, "reverseLiveness": 8, "reverseEndFade": 5, "reverbPredelay": 10, "reverbHighCut": 8000, "reverbWidth": 135, "reverbMix": 70],
        ["mix": 100, "eqBypass": 1, "driveBypass": 1, "compressorBypass": 1, "modBypass": 1, "delayBypass": 1, "reverbType": 6, "reverseTime": 180, "reverseCurve": 80, "reverseDensity": 85, "reverseLiveness": 4, "reverseEndFade": 5, "reverbPredelay": 0, "reverbMix": 35]
    ]
    private static let irPathKey = "BrumaImpulseResponsePath"
    private static let irMissingKey = "BrumaMissingImpulseResponse"

    private func makeParameterTree() {
        let parameters = Self.definitions.map { definition -> AUParameter in
            var flags: AudioUnitParameterOptions = [.flag_IsReadable, .flag_IsWritable]
            if definition.canRamp { flags.insert(.flag_CanRamp) }
            if definition.strings != nil { flags.insert(.flag_ValuesHaveStrings) }
            let parameter = AUParameterTree.createParameter(
                withIdentifier: definition.id, name: definition.name, address: definition.address,
                min: definition.min, max: definition.max, unit: definition.unit,
                unitName: nil, flags: flags, valueStrings: definition.strings, dependentParameters: nil
            )
            parameter.value = definition.initial
            return parameter
        }
        tree = AUParameterTree.createTree(withChildren: parameters)
        tree.implementorValueObserver = { [kernelAdapter] parameter, value in
            kernelAdapter.setParameter(parameter, value: value)
        }
        tree.implementorValueProvider = { [kernelAdapter] parameter in
            kernelAdapter.value(for: parameter)
        }
        tree.implementorStringFromValueCallback = { parameter, value in
            if let strings = Self.definitions.first(where: { $0.address == parameter.address })?.strings {
                let index = Int((value?.pointee ?? parameter.value).rounded())
                return strings.indices.contains(index) ? strings[index] : "—"
            }
            let current = value?.pointee ?? parameter.value
            switch parameter.unit {
            case .seconds: return String(format: "%.2f s", current)
            case .milliseconds: return String(format: "%.0f ms", current)
            case .hertz:
                if current >= 1000 { return String(format: "%.1f kHz", current / 1000) }
                if current < 10 { return String(format: "%.2f Hz", current) }
                return String(format: "%.0f Hz", current)
            case .decibels: return String(format: "%.1f dB", current)
            case .percent: return String(format: "%.0f%%", current)
            default: return String(format: "%.2f", current)
            }
        }
    }

    public func selectFactoryPreset(_ index: Int) {
        guard Self.presetValues.indices.contains(index) else { return }
        _currentPreset = factoryPresets[index]
        applyPreset(index)
    }

    private func applyPreset(_ index: Int) {
        guard Self.presetValues.indices.contains(index), let parameterTree else { return }
        // IR natural intentionally uses the currently imported room. Other
        // factory presets are independent of any previously loaded IR.
        if index != 11 { clearImpulseResponse() }
        // Reset all controls to Bruma defaults before applying a factory preset.
        for definition in Self.definitions {
            guard let parameter = parameterTree.parameter(withAddress: definition.address) else { continue }
            let value = Self.presetValues[0][definition.id] ?? definition.initial
            parameter.setValue(value, originator: nil)
        }
        for (identifier, value) in Self.presetValues[index] {
            parameterTree.parameter(withAddress: Self.definitions.first(where: { $0.id == identifier })?.address ?? 0)?
                .setValue(value, originator: nil)
        }
    }

    public func loadImpulseResponse(from sourceURL: URL) throws {
        try loadImpulseResponse(from: sourceURL, selectFullBlend: true)
    }

    public func loadImpulseResponseAsync(from sourceURL: URL, completion: @escaping (Result<BrumaIRImportMetadata, Error>) -> Void) {
        let generation = nextImpulseGeneration()
        let targetRate = outputBus.format.sampleRate
        impulseQueue.async { [self] in
            let result = Result { try importImpulse(from: sourceURL, targetRate: targetRate,
                                                   selectFullBlend: true, generation: generation, displayName: sourceURL.lastPathComponent) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func loadImpulseResponse(from url: URL, selectFullBlend: Bool, displayName: String? = nil) throws {
        let generation = nextImpulseGeneration()
        let rate = outputBus.format.sampleRate
        try impulseQueue.sync {
            _ = try importImpulse(from: url, targetRate: rate, selectFullBlend: selectFullBlend,
                                  generation: generation, displayName: displayName ?? url.lastPathComponent)
        }
    }

    // Windowed sinc conversion, with a reduced cutoff for downsampling. The
    // source/target ratio preserves the scale of discrete IR coefficients.
    public static func resampleImpulseChannel(_ samples: [Float], sourceRate: Double, targetRate: Double,
                                              outputLimit: Int = 32768, cancelled: (() -> Bool)? = nil) throws -> [Float] {
        guard sourceRate.isFinite, targetRate.isFinite, sourceRate >= 8000, sourceRate <= 384000,
              targetRate >= 8000, targetRate <= 192000, outputLimit > 0,
              !samples.isEmpty, samples.allSatisfy({ $0.isFinite }) else {
            throw NSError(domain: "Bruma.IR", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "La IR contiene un formato, una tasa o muestras no válidas."])
        }
        let ratio = sourceRate / targetRate
        let count = min(outputLimit, Int(ceil(Double(samples.count) / ratio)))
        if sourceRate == targetRate { return Array(samples.prefix(count)) }
        let cutoff = min(1, 1 / ratio) * 0.94
        let radius = Int(ceil(32 * max(1, ratio)))
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            if i & 127 == 0, cancelled?() == true { throw CocoaError(.userCancelled) }
            let position = Double(i) * ratio
            let center = Int(floor(position))
            var sum = 0.0, weightSum = 0.0
            for tap in (center - radius + 1)...(center + radius) {
                let distance = position - Double(tap)
                if abs(distance) >= Double(radius) { continue }
                let argument = Double.pi * cutoff * distance
                let sinc = abs(argument) < 1e-12 ? 1 : sin(argument) / argument
                let window = 0.42 + 0.5 * cos(Double.pi * distance / Double(radius)) + 0.08 * cos(2 * Double.pi * distance / Double(radius))
                let weight = cutoff * sinc * window
                weightSum += weight
                if samples.indices.contains(tap) { sum += Double(samples[tap]) * weight }
            }
            result[i] = Float(sum * ratio / max(1e-12, weightSum))
        }
        return result
    }

    private func importImpulse(from sourceURL: URL, targetRate: Double, selectFullBlend: Bool,
                               generation: UInt64, displayName: String) throws -> BrumaIRImportMetadata {
        guard withImpulseLock({ generation == impulseGeneration }) else { throw CocoaError(.userCancelled) }
        let startedScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if startedScope { sourceURL.stopAccessingSecurityScopedResource() } }
        let source = try AVAudioFile(forReading: sourceURL)
        let format = source.processingFormat
        guard source.length > 0, (1...2).contains(format.channelCount),
              format.sampleRate >= 8000, format.sampleRate <= 384000 else {
            throw NSError(domain: "Bruma.IR", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Usa una IR mono o estéreo con audio válido."])
        }
        let ratio = format.sampleRate / targetRate
        let frames = min(source.length, AVAudioFramePosition(ceil(32768 * ratio) + 64))
        // Leave conversion-chunk headroom: AVAudioFile can return fewer
        // frames than requested when the destination ends mid chunk.
        let readCapacity = AVAudioFrameCount(frames + AVAudioFramePosition(ceil(32 * max(1, ratio))) + 2048)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readCapacity) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try source.read(into: buffer, frameCount: readCapacity)
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let cancelled = { [self] in withImpulseLock { generation != impulseGeneration } }
        var left = try Self.resampleImpulseChannel(Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))),
                                                   sourceRate: format.sampleRate, targetRate: targetRate, cancelled: cancelled)
        var right = format.channelCount == 1 ? left : try Self.resampleImpulseChannel(
            Array(UnsafeBufferPointer(start: data[1], count: Int(buffer.frameLength))), sourceRate: format.sampleRate, targetRate: targetRate, cancelled: cancelled)
        let sourceDuration = Double(source.length) / format.sampleRate
        let metadata = BrumaIRImportMetadata(name: displayName, sourceDuration: sourceDuration,
            usedDuration: Double(left.count) / targetRate, sampleRate: targetRate,
            truncated: Double(source.length) / ratio > 32768)
        if metadata.truncated {
            let fade = min(128, left.count)
            for i in 0..<fade {
                let gain = Float(0.5 + 0.5 * cos(Double.pi * Double(i + 1) / Double(fade)))
                let index = left.count - fade + i
                left[index] *= gain; right[index] *= gain
            }
        }
        guard withImpulseLock({ generation == impulseGeneration }) else { throw CocoaError(.userCancelled) }
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("Bruma/Impulse Responses", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let localURL: URL
        let copied: Bool
        if sourceURL.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/") {
            localURL = sourceURL; copied = false
        } else {
            localURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(sourceURL.pathExtension)
            try FileManager.default.copyItem(at: sourceURL, to: localURL)
            copied = true
        }
        do {
            try withImpulseLock {
                guard generation == impulseGeneration else { throw CocoaError(.userCancelled) }
                let published = left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { r in
                    kernelAdapter.setImpulseLeft(l.baseAddress!, right: r.baseAddress!, count: UInt(l.count))
                } }
                guard published else {
                    throw NSError(domain: "Bruma.IR", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "No se pudo publicar la IR; la anterior sigue activa."])
                }
                impulseResponseURL = localURL
                missingImpulseName = nil
                impulseMetadata = metadata
                if selectFullBlend { tree.parameter(withAddress: 48)?.setValue(100, originator: nil) }
            }
        } catch {
            if copied { try? FileManager.default.removeItem(at: localURL) }
            throw error
        }
        return metadata
    }

    public func clearImpulseResponse() { discardImpulse(resetBlend: true) }

    private func discardImpulse(resetBlend: Bool, missingName: String? = nil) {
        withImpulseLock {
            impulseGeneration &+= 1
            kernelAdapter.clearImpulse()
            impulseResponseURL = nil; impulseMetadata = nil; missingImpulseName = missingName
            if resetBlend { tree.parameter(withAddress: 48)?.setValue(0, originator: nil) }
        }
    }

    private func restoreImpulse(from url: URL, displayName: String? = nil) {
        do { try loadImpulseResponse(from: url, selectFullBlend: false, displayName: displayName) }
        catch {
            if (error as NSError).code != NSUserCancelledError {
                discardImpulse(resetBlend: false, missingName: displayName ?? url.lastPathComponent)
            }
        }
    }

    public var impulseResponseName: String? { withImpulseLock { missingImpulseName ?? impulseMetadata?.name ?? impulseResponseURL?.lastPathComponent } }
    public var hasMissingImpulseResponse: Bool { withImpulseLock { missingImpulseName != nil } }
    public var impulseResponseMetadata: BrumaIRImportMetadata? { withImpulseLock { impulseMetadata } }

    public var inputLevel: Float { kernelAdapter.inputMeter() }
    public var outputLevel: Float { kernelAdapter.outputMeter() }

    public override func allocateRenderResources() throws {
        let input = inputBus.format
        let output = outputBus.format
        guard input.commonFormat == .pcmFormatFloat32, output.commonFormat == .pcmFormatFloat32,
              !input.isInterleaved, !output.isInterleaved,
              input.channelCount == 2, output.channelCount == 2,
              input.sampleRate == output.sampleRate, output.sampleRate >= 8000, output.sampleRate <= 192000 else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        try super.allocateRenderResources()
        // Resource initialization cannot overlap FFT preparation/publication.
        _ = nextImpulseGeneration()
        impulseQueue.sync { withImpulseLock { kernelAdapter.allocateRenderResources() } }
        let saved = withImpulseLock { (impulseResponseURL, impulseMetadata?.name) }
        if let url = saved.0 { restoreImpulse(from: url, displayName: saved.1) }
    }

    public override func deallocateRenderResources() {
        kernelAdapter.deallocateRenderResources()
        super.deallocateRenderResources()
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        let render = kernelAdapter.internalRenderBlock()
        let tempoBlock = musicalContextBlock
        let adapter = kernelAdapter
        return { flags, timestamp, frameCount, outputBusNumber, outputData, events, pullInput in
            if let tempoBlock {
                var bpm = 120.0
                if tempoBlock(&bpm, nil, nil, nil, nil, nil) { adapter.setTempo(bpm) }
            }
            return render(flags, timestamp, frameCount, outputBusNumber, outputData, events, pullInput)
        }
    }
}
