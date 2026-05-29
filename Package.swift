// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Harness",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HarnessCore", targets: ["HarnessCore"]),
        // Self-contained native terminal engine (VT parser + screen/grid model). Pure
        // Swift, no Metal/AppKit — replaces the libghostty fork's GhosttyTerminal. Grows
        // alongside the fork (which stays as an A/B correctness oracle) until cutover.
        .library(name: "HarnessTerminalEngine", targets: ["HarnessTerminalEngine"]),
        // Native theme catalog + the shareable `.harnesstheme` document format. Pure
        // Swift — replaces the libghostty fork's GhosttyTheme.
        .library(name: "HarnessTheme", targets: ["HarnessTheme"]),
        // Native terminal renderer. Color-resolution layer is pure Swift (tested without
        // a GPU); the Metal glyph/draw layer is added in a later phase.
        .library(name: "HarnessTerminalRenderer", targets: ["HarnessTerminalRenderer"]),
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
        // Native terminal engine — pure Swift, no external dependencies. Foundation only
        // so it links for headless CLI use and unit tests without a GPU.
        .target(
            name: "HarnessTerminalEngine",
            path: "Packages/HarnessTerminalEngine/Sources/HarnessTerminalEngine"
        ),
        // Native theme system — pure Swift, no external dependencies.
        .target(
            name: "HarnessTheme",
            path: "Packages/HarnessTheme/Sources/HarnessTheme"
        ),
        // Native renderer — depends on the engine (grid types) and theme (colors). The
        // color-resolution layer here is pure Swift; Metal/CoreText code lands later.
        .target(
            name: "HarnessTerminalRenderer",
            dependencies: ["HarnessTerminalEngine", "HarnessTheme"],
            path: "Packages/HarnessTerminalRenderer/Sources/HarnessTerminalRenderer"
        ),
        .target(
            name: "HarnessTerminalKit",
            dependencies: [
                "HarnessCore",
                "HarnessTerminalEngine",
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
            dependencies: ["HarnessCore", "HarnessTerminalEngine", "HarnessTerminalKit"],
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
            name: "HarnessTerminalEngineTests",
            dependencies: ["HarnessTerminalEngine"],
            path: "Tests/HarnessTerminalEngineTests"
        ),
        .testTarget(
            name: "HarnessThemeTests",
            dependencies: ["HarnessTheme"],
            path: "Tests/HarnessThemeTests"
        ),
        .testTarget(
            name: "HarnessTerminalRendererTests",
            dependencies: ["HarnessTerminalRenderer", "HarnessTerminalEngine", "HarnessTheme"],
            path: "Tests/HarnessTerminalRendererTests"
        ),
        .testTarget(
            name: "HarnessTerminalKitTests",
            dependencies: [
                "HarnessCore",
                "HarnessTerminalEngine",
                "HarnessTerminalKit",
                // Still present so HeadlessGridReadTests can A/B the new engine against
                // the libghostty GridTerminal oracle until the fork is removed (Phase 8).
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
