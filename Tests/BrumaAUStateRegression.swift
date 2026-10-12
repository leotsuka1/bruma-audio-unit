import Foundation
import AudioToolbox
import AUv3FilterFramework

func require(_ condition: Bool, _ name: String) {
    if !condition { fatalError("FAIL: \(name)") }
}
let description = AudioComponentDescription(componentType: kAudioUnitType_Effect,
    componentSubType: 0x42726D61, componentManufacturer: 0x4C74736B, componentFlags: 0, componentFlagsMask: 0)
let unit = try AUv3FilterDemo(componentDescription: description)
let tree = unit.parameterTree!
func parameter(_ id: String) -> AUParameter { tree.parameter(withAddress: AUv3FilterDemo.address(for: id))! }
parameter("mix").value = 73
parameter("cutoff").value = 19
parameter("room").value = 41
parameter("resonance").value = 26
parameter("tone").value = 88
parameter("reverbDamping").value = 24
parameter("delayDivision").value = 9
parameter("driveCharacter").value = 5
parameter("reverseTime").value = 725
parameter("reverseCurve").value = 93
parameter("reverseLiveness").value = 7
parameter("reverbType").value = 6
let state = unit.fullState!
let expected = Dictionary(uniqueKeysWithValues: AUv3FilterDemo.displayParameters.map { ($0.identifier, parameter($0.identifier).value) })
unit.selectFactoryPreset(3)
unit.fullState = state
for (id, value) in expected { require(parameter(id).value == value, "snapshot round trip: \(id)") }
require(unit.fullState?["Bruma.StateSchemaVersion"] as? Int == 1, "schema version")
unit.selectFactoryPreset(0)
parameter("room").value = 17
unit.selectFactoryPreset(0)
require(parameter("room").value == 58, "explicit reapply restores factory defaults")
parameter("room").value = 22
unit.currentPreset = unit.factoryPresets[0]
require(parameter("room").value == 22, "host reassert preserves edits")
var missingIRState = unit.fullState!
missingIRState["BrumaImpulseResponsePath"] = "/bruma-regression-missing-room.wav"
unit.fullState = missingIRState
require(unit.hasMissingImpulseResponse, "missing IR is reported")
require(parameter("room").value == 22, "missing IR preserves parameters")

let keys = ["Bruma.LocalUserPresets.v1", "Bruma.LocalUserPresets.NextNumber"]
let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
defer {
    for (index, key) in keys.enumerated() {
        if let original = saved[index] { UserDefaults.standard.set(original, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
}
for key in keys { UserDefaults.standard.removeObject(forKey: key) }
let a = try unit.saveBrumaUserPreset(named: "Regression A")
let b = try unit.saveBrumaUserPreset(named: "Regression B")
unit.deleteBrumaUserPreset(a)
require(unit.brumaUserPresets.first?.id == b.id && unit.brumaUserPresets.first?.number == b.number, "delete preserves other preset identity")
unit.deleteBrumaUserPreset(b)
let c = try unit.saveBrumaUserPreset(named: "Regression C")
require(c.number < b.number, "deleted preset numbers are not reused")
print("PASS: \(AUv3FilterDemo.displayParameters.count)-parameter state round trip, preset reapply, host reassert, missing IR and stable user preset identity")

for index in [21, 22, 23] {
    unit.selectFactoryPreset(index)
    require(parameter("reverbType").value == 6, "Reverse factory preset")
    require(parameter("mix").value == 100 && parameter("delayBypass").value == 1, "Reverse factory chain isolation")
}
print("PASS: three Reverse Gate factory presets")
