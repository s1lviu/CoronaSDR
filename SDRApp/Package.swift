// swift-tools-version: 6.0
import PackageDescription

// Root Package.swift — all local packages as targets.
// The iOS app target is created via Xcode project (project.yml + xcodegen).
let package = Package(
    name: "SDRApp",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "RTLTCPClientKit", targets: ["RTLTCPClientKit"]),
        .library(name: "SDRCoreDSP", targets: ["SDRCoreDSP"]),
        .library(name: "SDRRender", targets: ["SDRRender"]),
        .library(name: "AudioEngineKit", targets: ["AudioEngineKit"]),
        .library(name: "SDRModels", targets: ["SDRModels"]),
        .library(name: "SDRSupport", targets: ["SDRSupport"]),
        .library(name: "CLiquidDSP", targets: ["CLiquidDSP"]),
    ],
    dependencies: [],
    targets: [
        // CLiquidDSP Wrapper
        .target(
            name: "CLiquidDSP",
            dependencies: [],
            path: "Packages/CLiquidDSP/Sources/CLiquidDSP",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include")
            ]
        ),

        // SDRSupport
        .target(
            name: "SDRSupport",
            dependencies: [],
            path: "Packages/SDRSupport/Sources/SDRSupport"
        ),

        // SDRModels
        .target(
            name: "SDRModels",
            dependencies: ["SDRSupport"],
            path: "Packages/SDRModels/Sources/SDRModels"
        ),

        // RTLTCPClientKit
        .target(
            name: "RTLTCPClientKit",
            dependencies: ["SDRSupport", "SDRModels"],
            path: "Packages/RTLTCPClientKit/Sources/RTLTCPClientKit"
        ),

        // AudioEngineKit
        .target(
            name: "AudioEngineKit",
            dependencies: ["SDRSupport"],
            path: "Packages/AudioEngineKit/Sources/AudioEngineKit"
        ),

        // SDRCoreDSP
        .target(
            name: "SDRCoreDSP",
            dependencies: ["SDRSupport", "SDRModels", "AudioEngineKit", "RTLTCPClientKit", "CLiquidDSP"],
            path: "Packages/SDRCoreDSP/Sources/SDRCoreDSP",
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedLibrary("liquid"),
                .unsafeFlags(["-LPackages/CLiquidDSP/lib"])
            ]
        ),

        // SDRRender
        .target(
            name: "SDRRender",
            dependencies: ["SDRSupport"],
            path: "Packages/SDRRender/Sources/SDRRender",
            resources: [
                .process("Shaders"),
            ]
        ),
    ]
)
