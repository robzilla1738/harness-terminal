import Foundation
import HarnessCore
import XCTest

final class TrustedPluginsTests: XCTestCase {
    func testDeclarativeReviewCapturesApprovedEntryAndRevocationRefusesInvocation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hplugin-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestURL = root.appendingPathComponent("plugin.json"), sourceURL = root.appendingPathComponent("entry.lua"), registry = root.appendingPathComponent("trusted.json")
        let manifest = PluginManifest(id: "fixture", title: "Fixture", actions: [PluginAction(id: "run", title: "Run fixture", file: "entry.lua")])
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        try Data("error('must never execute during review')".utf8).write(to: sourceURL)
        let proposal = try TrustedPlugins.prepare(manifestURL)
        XCTAssertEqual(proposal.sources["entry.lua"], "error('must never execute during review')")
        XCTAssertThrowsError(try TrustedPlugins.source(plugin: "fixture", action: "run", from: registry))
        try TrustedPlugins.approve(proposal, at: registry)
        try Data("error('unreviewed change')".utf8).write(to: sourceURL)
        XCTAssertEqual(try TrustedPlugins.source(plugin: "fixture", action: "run", from: registry), proposal.sources["entry.lua"])
        try TrustedPlugins.revoke("fixture", at: registry)
        XCTAssertThrowsError(try TrustedPlugins.source(plugin: "fixture", action: "run", from: registry))
        try FileManager.default.removeItem(at: sourceURL)
        try FileManager.default.createSymbolicLink(at: sourceURL, withDestinationURL: manifestURL)
        XCTAssertThrowsError(try TrustedPlugins.prepare(manifestURL))
        var unsafe = manifest; unsafe.actions[0].file = "../outside.lua"
        XCTAssertThrowsError(try unsafe.validate())
    }
}
