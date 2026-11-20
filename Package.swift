// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wave",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WaveCore", targets: ["WaveCore"]),
        .library(name: "WaveUI", targets: ["WaveUI"]),
        .executable(name: "wave-probe", targets: ["wave-probe"]),
        .executable(name: "wave-debug", targets: ["wave-debug"]),
    ],
    targets: [
        // Tiny C shim: C11 atomics for the lock-free audio ring buffer and an
        // async-signal-safe Ctrl-C flag. (Swift's Synchronization.Atomic needs macOS 15.)
        .target(name: "WaveRT", path: "Sources/WaveRT"),
        .target(name: "WaveCore", dependencies: ["WaveRT"], path: "Sources/WaveCore"),
        // SwiftUI debug views (spectrogram, traces, event log), reused by the menu bar app in M2.
        .target(name: "WaveUI", dependencies: ["WaveCore"], path: "Sources/WaveUI"),
        .executableTarget(name: "wave-debug", dependencies: ["WaveCore", "WaveUI"], path: "Sources/wave-debug"),
        .executableTarget(name: "wave-probe", dependencies: ["WaveCore", "WaveRT"], path: "Sources/wave-probe"),
        .testTarget(name: "WaveCoreTests", dependencies: ["WaveCore"], path: "Tests/WaveCoreTests"),
    ]
)
