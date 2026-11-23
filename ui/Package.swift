// swift-tools-version: 6.2
// Warm-up menu-bar companion. Dependency-free: AppKit, SwiftUI and Foundation only.
// App shell adapted from Nameplate (MIT, Peter Steinberger); see NOTICE.md.

import PackageDescription

let package = Package(
    name: "WarmupMenu",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "WarmupMenu", targets: ["WarmupMenu"]),
    ],
    targets: [
        .target(name: "WarmupCore"),
        .executableTarget(name: "WarmupMenu", dependencies: ["WarmupCore"]),
        .testTarget(name: "WarmupCoreTests", dependencies: ["WarmupCore"]),
    ])
