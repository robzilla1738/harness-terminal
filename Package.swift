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
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.2.0"),
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
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
            ],
            path: "Packages/HarnessTerminalKit/Sources/HarnessTerminalKit"
        ),
        .executableTarget(
            name: "HarnessDaemon",
            dependencies: ["HarnessCore"],
            path: "Packages/HarnessDaemon/Sources/HarnessDaemon"
        ),
        .executableTarget(
            name: "HarnessCLI",
            dependencies: ["HarnessCore"],
            path: "Tools/harness/Sources/HarnessCLI"
        ),
        .executableTarget(
            name: "HarnessApp",
            dependencies: [
                "HarnessCore",
                "HarnessTerminalKit",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
            ],
            path: "Apps/Harness/Sources/HarnessApp",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "HarnessCoreTests",
            dependencies: ["HarnessCore"],
            path: "Tests/HarnessCoreTests"
        ),
    ]
)
