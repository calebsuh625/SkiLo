// swift-tools-version: 6.0
// SkiLo — native macOS ski progression tracker for Heavenly Mountain Resort.
// Built with Command Line Tools only (no Xcode license required): see Makefile / README.md.
import PackageDescription
import Foundation

// --- CLT quirk: swift-testing search paths ---------------------------------------------------
// Command Line Tools ships Testing.framework at <CLT>/Library/Developer/Frameworks and its
// lib_TestingInterop.dylib at <CLT>/Library/Developer/usr/lib — a different relative layout
// than Xcode's platform directory — so `swift test` can't find them on its own
// ("no such module 'Testing'" / "Library not loaded: @rpath/lib_TestingInterop.dylib").
// When DEVELOPER_DIR points at CLT we add the search paths + rpaths to the test target only.
// (XCTest is not shipped with CLT at all; write tests with `import Testing`.)
let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? ""
let usingCLT = developerDir.contains("CommandLineTools")
let cltFrameworks = developerDir + "/Library/Developer/Frameworks"
let cltInteropLib = developerDir + "/Library/Developer/usr/lib"

let testSwiftFlags: [SwiftSetting] = usingCLT ? [.unsafeFlags(["-F", cltFrameworks])] : []
let testLinkerFlags: [LinkerSetting] = usingCLT ? [.unsafeFlags([
    "-F", cltFrameworks,
    "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
    "-Xlinker", "-rpath", "-Xlinker", cltInteropLib,
])] : []

let package = Package(
    name: "SkiLo",
    platforms: [
        .macOS(.v15),
    ],
    targets: [
        .executableTarget(
            name: "SkiLo",
            path: "Sources/SkiLo",
            // Whole Resources/ directory is copied verbatim into the resource bundle
            // (SkiLo_SkiLo.bundle/Resources/...). In app code use
            // Bundle.appResources (Sources/SkiLo/AppResources.swift), NOT Bundle.module:
            // SwiftPM's generated Bundle.module never looks in <app>/Contents/Resources.
            resources: [
                .copy("Resources"),
            ],
            swiftSettings: [
                // Swift 5 language mode: SwiftUI/MapKit/SceneKit delegate code trips Swift 6
                // strict-concurrency *errors*; in v5 mode they are warnings only.
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "SkiLoTests",
            dependencies: ["SkiLo"],
            path: "Tests/SkiLoTests",
            swiftSettings: [.swiftLanguageMode(.v5)] + testSwiftFlags,
            linkerSettings: testLinkerFlags
        ),
    ]
)
