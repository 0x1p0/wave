import CoreAudio
import Foundation
import WaveCore

/// `wave-probe devices`: machine + audio hardware report. Plays and records nothing.
enum DevicesCommand {
    static func run() -> Int32 {
        let machine = MachineInfo.current()
        print(Term.bold("Machine"))
        print("  \(machine.summary)")
        print()

        let all = AudioDevices.all()
        let speakers = AudioDevices.builtInSpeakers()
        let mic = AudioDevices.builtInMicrophone()
        let defaultOut = AudioDevices.defaultOutputID()
        let defaultIn = AudioDevices.defaultInputID()

        print(Term.bold("All audio devices"))
        for d in all {
            var tags: [String] = []
            if d.id == speakers?.id { tags.append("← Wave pilot output") }
            if d.id == mic?.id { tags.append("← Wave capture input") }
            if d.id == defaultOut { tags.append("default output") }
            if d.id == defaultIn { tags.append("default input") }
            print("  • \(d.name)  \(Term.dim("[\(d.uid)]"))  \(tags.joined(separator: ", "))")
            var io: [String] = []
            if d.inputChannels > 0 {
                io.append("in \(d.inputChannels) ch" + (d.inputDataSource.map { " src '\(fourCCString($0))'" } ?? ""))
            }
            if d.outputChannels > 0 {
                io.append("out \(d.outputChannels) ch" + (d.outputDataSource.map { " src '\(fourCCString($0))'" } ?? ""))
            }
            print("      \(d.transportName), \(io.joined(separator: ", ")), \(Int(d.nominalSampleRate)) Hz (supports \(d.sampleRatesDescription))")
        }
        print()

        guard let speakers, let mic else {
            print("✗ Could not find the built-in \(speakers == nil ? "speakers" : "microphone").")
            return 2
        }
        let spk = Environment.speakerState(speakers)
        print(Term.bold("Wave will use"))
        print("  Pilot  → \(speakers.name): \(speakers.outputChannels) ch @ \(Int(speakers.nominalSampleRate)) Hz, \(spk.summary)")
        let micGain = AudioDevices.volumeScalar(mic.id, scope: kAudioObjectPropertyScopeInput)
        print("  Capture← \(mic.name): \(mic.inputChannels) ch @ \(Int(mic.nominalSampleRate)) Hz (supports \(mic.sampleRatesDescription))"
              + (micGain.map { ", input gain \(Int(($0 * 100).rounded()))%" } ?? ""))
        print("  Mic permission for this terminal: \(Environment.permissionName(MicCapture.permission))")
        print("  Mic mode (Control Center): \(Environment.micModeName())  (raw AUHAL capture; no voice processing/AGC)")
        if let fatal = spk.fatal { print("\n✗ \(fatal)") }
        if let warning = spk.warning { print("\n! \(warning)") }
        return 0
    }
}
