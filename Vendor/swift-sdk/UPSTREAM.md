# Official MCP Swift SDK

`Sources/MCP` and `LICENSE` from `modelcontextprotocol/swift-sdk`, release
`0.12.1`, commit `a0ae212ebf6eab5f754c3129608bc5557637e605`.

The upstream `Package@swift-6.0.swift` is selected as `Package.swift` so every build
uses the supplied Swift 6.0-compatible manifest. Its three dependency versions are
fixed to Swift 6.0-compatible releases (swift-system 1.4.2, swift-log 1.6.4,
eventsource 1.1.0). This avoids the main manifest's
optional conformance executables, SwiftNIO and documentation-plugin branch dependency.
One local correctness patch in `Sources/MCP/Server/Server.swift` returns the SDK's
strict-lifecycle error when a request arrives before initialization. Upstream 0.12.1
otherwise discards this thrown error with `try?`, leaving the caller waiting forever.
The real stdio proof checks this path. Protocol schemas and advertised versions are
unchanged; all other SDK source files match the verified release.

Upstream: https://github.com/modelcontextprotocol/swift-sdk/tree/0.12.1
License: MIT (`LICENSE`). Updates replace the SDK from a verified upstream release;
Harness-specific behavior belongs in `Packages/HarnessMCP`.
