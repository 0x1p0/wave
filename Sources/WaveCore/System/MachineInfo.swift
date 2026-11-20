import Foundation

/// Identifies the Mac (model, chip, OS) for probe reports. Never includes serial numbers.
public struct MachineInfo: Sendable {
    public let modelName: String        // "MacBook Air"
    public let modelIdentifier: String  // "Mac16,12"
    public let chip: String             // "Apple M4"
    public let osVersion: String        // "27.2.1 (26B131)"

    public var summary: String { "\(modelName) (\(modelIdentifier), \(chip)), macOS \(osVersion)" }

    public static func current() -> MachineInfo {
        let identifier = sysctlString("hw.model") ?? "unknown"
        var chip = sysctlString("machdep.cpu.brand_string") ?? "unknown"
        var name = identifier

        // system_profiler knows the marketing name; read only the fields we need.
        if let json = runTool("/usr/sbin/system_profiler", ["SPHardwareDataType", "-json"]),
           let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
           let items = root["SPHardwareDataType"] as? [[String: Any]],
           let hw = items.first {
            if let n = hw["machine_name"] as? String { name = n }
            if let c = hw["chip_type"] as? String { chip = c }
        }

        let v = ProcessInfo.processInfo.operatingSystemVersion
        var os = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        if let build = sysctlString("kern.osversion") { os += " (\(build))" }
        return MachineInfo(modelName: name, modelIdentifier: identifier, chip: chip, osVersion: os)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func runTool(_ path: String, _ args: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
