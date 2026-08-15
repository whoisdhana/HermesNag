// swift-tools-version:5.9
//
// SwiftPM, not XcodeGen — correction C4 in docs/00-discovery.md.
// Command Line Tools alone build and ad-hoc sign a working .app, so this
// project file is regenerable by construction (spec: "must be regenerable,
// not hand-edited") with no 15GB dependency.
//
//   swift build -c release      # binary
//   make -C .. bundle           # .app + Info.plist + codesign
//   swift test                  # pure-logic tests, no UI

import PackageDescription

let package = Package(
    name: "HermesNag",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: no SwiftUI, no AppKit. Fully unit-testable with an
        // injected clock, which is what keeps the tests instant.
        .target(name: "HermesNagCore"),

        // The app shell. Thin by design — anything worth testing lives in Core.
        .executableTarget(
            name: "HermesNag",
            dependencies: ["HermesNagCore"]
        ),

        .testTarget(
            name: "HermesNagCoreTests",
            dependencies: ["HermesNagCore"]
        ),
    ]
)
