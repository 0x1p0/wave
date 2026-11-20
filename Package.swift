// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wave",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WaveCore", targets: ["WaveCore"]),
        .executable(name: "wave-probe", targets: ["wave-probe"]),
    ],
    targets: [
        // Tiny C shim: C11 atomics for the lock-free audio ring buffer and an
        // async-signal-safe Ctrl-C flag. (Swift's Synchronization.Atomic needs macOS 15.)
        .target(name: "WaveRT", path: "Sources/WaveRT"),
        .target(name: "WaveCore", dependencies: ["WaveRT"], path: "Sources/WaveCore"),
        .executableTarget(name: "wave-probe", dependencies: ["WaveCore", "WaveRT"], path: "Sources/wave-probe"),
        .testTarget(name: "WaveCoreTests", dependencies: ["WaveCore"], path: "Tests/WaveCoreTests"),
    ]
)
