// swift-tools-version: 6.0
import PackageDescription

// The whole package builds in the Swift 6 language mode (tools-version 6.0), so *complete* strict
// concurrency checking is already on everywhere. For the two pure, foundational, dependency-free
// libraries — HarnessCore (models/IPC/commands) and HarnessTerminalEngine (VT engine) — we also
// treat warnings as errors so a data-race / Sendable / deprecation warning in the layer everything
// else builds on can never be ignored and rot. Kept off the AppKit/Metal targets for now (they
// surface framework-deprecation churn we don't want to hard-fail CI on).
let strictFoundationSettings: [SwiftSetting] = [.unsafeFlags(["-warnings-as-errors"])]

let package = Package(
    name: "Harness",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HarnessCore", targets: ["HarnessCore"]),
        // Self-contained native terminal engine (VT parser + screen/grid model). Pure
        // Swift, no Metal/AppKit.
        .library(name: "HarnessTerminalEngine", targets: ["HarnessTerminalEngine"]),
        // Shared, UI-agnostic copy-mode model (state + pure reducer over the engine grid),
        // driving copy mode in both the GUI overlay and the ssh compositor. Pure Swift.
        .library(name: "HarnessCopyMode", targets: ["HarnessCopyMode"]),
        // Native theme catalog + the shareable `.harnesstheme` document format. Pure Swift.
        .library(name: "HarnessTheme", targets: ["HarnessTheme"]),
        // Native terminal renderer: pure-Swift color resolution + a Metal glyph/draw layer.
        .library(name: "HarnessTerminalRenderer", targets: ["HarnessTerminalRenderer"]),
        .library(name: "HarnessTerminalKit", targets: ["HarnessTerminalKit"]),
        // Immersive first-run onboarding wizard (SwiftUI). Self-contained, no deps; embedded
        // into Harness.app and shown on first launch.
        .library(name: "HarnessOnboarding", targets: ["HarnessOnboarding"]),
        .executable(name: "Harness", targets: ["HarnessApp"]),
        .executable(name: "HarnessDaemon", targets: ["HarnessDaemon"]),
        .executable(name: "harness-cli", targets: ["HarnessCLI"]),
    ],
    dependencies: [
        // Sparkle: macOS auto-update (the only external dependency, and only for the GUI app —
        // the engine/daemon/CLI stay first-party). Appcast hosted at harnesscli.dev.
        // Pinned to the audited 2.9.x line (`Package.resolved` locks 2.9.2): a fresh resolve can't
        // float onto an unaudited future major/minor, while patch-level security fixes still land.
        .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMinor(from: "2.9.2")),
    ],
    targets: [
        .target(
            name: "HarnessCore",
            path: "Packages/HarnessCore/Sources/HarnessCore",
            swiftSettings: strictFoundationSettings
        ),
        // Native terminal engine — pure Swift, no external dependencies. Foundation only
        // so it links for headless CLI use and unit tests without a GPU.
        .target(
            name: "HarnessTerminalEngine",
            path: "Packages/HarnessTerminalEngine/Sources/HarnessTerminalEngine",
            swiftSettings: strictFoundationSettings
        ),
        // Shared copy-mode model — pure Swift over Core (action vocabulary) + the engine
        // (grid types). Both the GUI surface and the compositor drive this one reducer.
        .target(
            name: "HarnessCopyMode",
            dependencies: ["HarnessCore", "HarnessTerminalEngine"],
            path: "Packages/HarnessCopyMode/Sources/HarnessCopyMode"
        ),
        // Native theme system — pure Swift, no external dependencies.
        .target(
            name: "HarnessTheme",
            path: "Packages/HarnessTheme/Sources/HarnessTheme",
            // The community catalog is embedded as base64 in BundledThemesData.swift (compiled
            // into the binary), NOT shipped as a SwiftPM resource bundle: a missing/misplaced
            // `Bundle.module` bundle crashed the app at launch for users on a non-builtin theme.
            // themes.json stays as the editable source of truth but is excluded from the build —
            // regenerate the embed with `EXPORT_THEMES=1 swift test --filter ThemeCatalogEmbedTests`.
            exclude: ["Resources/themes.json"]
        ),
        // Native renderer — first-party frame building, CoreText glyph atlas, and Metal drawing.
        .target(
            name: "HarnessTerminalRenderer",
            dependencies: ["HarnessCore", "HarnessTerminalEngine", "HarnessTheme"],
            path: "Packages/HarnessTerminalRenderer/Sources/HarnessTerminalRenderer"
        ),
        .target(
            name: "HarnessTerminalKit",
            dependencies: [
                "HarnessCore",
                "HarnessTerminalEngine",
                "HarnessCopyMode",
                "HarnessTerminalRenderer",
                "HarnessTheme",
            ],
            path: "Packages/HarnessTerminalKit/Sources/HarnessTerminalKit"
        ),
        // Immersive onboarding wizard — pure SwiftUI/AppKit, no external or first-party
        // dependencies (deliberately isolated, mirrors install paths via its own helpers).
        .target(
            name: "HarnessOnboarding",
            path: "Packages/HarnessOnboarding/Sources/HarnessOnboarding"
        ),
        // Daemon logic as a library so it is unit-testable; the executable below is a
        // thin `main.swift` wrapper over it.
        .target(
            name: "HarnessDaemonCore",
            // Depends on the engine so `capture-pane` reconstructs the on-screen grid
            // (faithful overwrites/clears + soft-wrap join), exactly like tmux.
            dependencies: ["HarnessCore", "HarnessTerminalEngine"],
            path: "Packages/HarnessDaemon/Sources/HarnessDaemon"
        ),
        .executableTarget(
            name: "HarnessDaemon",
            dependencies: ["HarnessDaemonCore"],
            path: "Packages/HarnessDaemon/Sources/HarnessDaemonMain"
        ),
        .executableTarget(
            name: "HarnessCLI",
            dependencies: ["HarnessCore", "HarnessTerminalEngine", "HarnessCopyMode", "HarnessTerminalKit", "HarnessTheme"],
            path: "Tools/harness/Sources/HarnessCLI"
        ),
        .executableTarget(
            name: "HarnessApp",
            dependencies: [
                "HarnessCore",
                "HarnessTerminalKit",
                "HarnessTheme",
                "HarnessOnboarding",
                .product(name: "Sparkle", package: "Sparkle"),
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
            name: "HarnessCopyModeTests",
            dependencies: ["HarnessCopyMode", "HarnessCore", "HarnessTerminalEngine"],
            path: "Tests/HarnessCopyModeTests"
        ),
        .testTarget(
            name: "HarnessThemeTests",
            dependencies: ["HarnessTheme"],
            path: "Tests/HarnessThemeTests"
        ),
        .testTarget(
            name: "HarnessTerminalRendererTests",
            dependencies: ["HarnessCore", "HarnessTerminalRenderer", "HarnessTerminalEngine", "HarnessTheme"],
            path: "Tests/HarnessTerminalRendererTests"
        ),
        .testTarget(
            name: "HarnessTerminalKitTests",
            dependencies: [
                "HarnessCore",
                "HarnessTerminalEngine",
                "HarnessCopyMode",
                "HarnessTerminalKit",
                "HarnessTheme",
            ],
            path: "Tests/HarnessTerminalKitTests"
        ),
        .testTarget(
            name: "HarnessOnboardingTests",
            dependencies: ["HarnessOnboarding"],
            path: "Tests/HarnessOnboardingTests"
        ),
        .testTarget(
            name: "HarnessDaemonTests",
            dependencies: ["HarnessDaemonCore", "HarnessCore"],
            path: "Tests/HarnessDaemonTests"
        ),
        // Performance baselines for the hot paths (VT parse, IPC codec, scrollback,
        // compositor, renderer stats). Gated behind HARNESS_BENCHMARKS=1 so a normal
        // `swift test` stays fast; run with `make bench`.
        .testTarget(
            name: "HarnessBenchmarks",
            dependencies: [
                "HarnessCore",
                "HarnessTerminalEngine",
                "HarnessTerminalKit",
                "HarnessTerminalRenderer",
                "HarnessTheme",
            ],
            path: "Tests/HarnessBenchmarks"
        ),
    ]
)
