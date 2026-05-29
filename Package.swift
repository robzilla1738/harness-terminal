// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Harness",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HarnessCore", targets: ["HarnessCore"]),
        .library(name: "HarnessTerminalKit", targets: ["HarnessTerminalKit"]),
        .executable(name: "Harness", targets: ["HarnessApp"]),
        .executable(name: "HarnessDaemon", targets: ["HarnessDaemon"]),
        .executable(name: "harness-cli", targets: ["HarnessCLI"]),
    ],
    dependencies: [
        // Harness's libghostty fork (read-cells styled-grid API + Display-P3
        // colorspace). Pinned by revision; its XCFramework resolves from a GitHub
        // release asset by url+checksum, so a clean clone builds with no sibling
        // checkout and no Zig rebuild. For local fork development, temporarily swap
        // this back to `.package(path: "../libghostty-spm-fork")`.
        .package(
            url: "https://github.com/robzilla1738/libghostty-spm-fork.git",
            revision: "16f6d4fd91ccc2688a5e7e835506e3b85c65ea2f"
        ),
    ],
    targets: [
        .target(
            name: "HarnessCore",
            path: "Packages/HarnessCore/Sources/HarnessCore"
        ),
        .target(
            name: "HarnessTerminalKit",
            dependencies: [
                "HarnessCore",
                .product(name: "GhosttyTerminal", package: "libghostty-spm-fork"),
                .product(name: "GhosttyTheme", package: "libghostty-spm-fork"),
            ],
            path: "Packages/HarnessTerminalKit/Sources/HarnessTerminalKit"
        ),
        // Daemon logic as a library so it is unit-testable; the executable below is a
        // thin `main.swift` wrapper over it.
        .target(
            name: "HarnessDaemonCore",
            dependencies: ["HarnessCore"],
            path: "Packages/HarnessDaemon/Sources/HarnessDaemon"
        ),
        .executableTarget(
            name: "HarnessDaemon",
            dependencies: ["HarnessDaemonCore"],
            path: "Packages/HarnessDaemon/Sources/HarnessDaemonMain"
        ),
        .executableTarget(
            name: "HarnessCLI",
            dependencies: ["HarnessCore", "HarnessTerminalKit"],
            path: "Tools/harness/Sources/HarnessCLI"
        ),
        .executableTarget(
            name: "HarnessApp",
            dependencies: [
                "HarnessCore",
                "HarnessTerminalKit",
                .product(name: "GhosttyTerminal", package: "libghostty-spm-fork"),
                .product(name: "GhosttyTheme", package: "libghostty-spm-fork"),
            ],
            path: "Apps/Harness/Sources/HarnessApp",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "HarnessCoreTests",
            dependencies: ["HarnessCore"],
            path: "Tests/HarnessCoreTests"
        ),
        .testTarget(
            name: "HarnessTerminalKitTests",
            dependencies: [
                "HarnessCore",
                "HarnessTerminalKit",
                .product(name: "GhosttyTerminal", package: "libghostty-spm-fork"),
            ],
            path: "Tests/HarnessTerminalKitTests"
        ),
        .testTarget(
            name: "HarnessDaemonTests",
            dependencies: ["HarnessDaemonCore", "HarnessCore"],
            path: "Tests/HarnessDaemonTests"
        ),
    ]
)
