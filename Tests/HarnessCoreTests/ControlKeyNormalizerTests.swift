import XCTest
@testable import HarnessCore

final class ControlKeyNormalizerTests: XCTestCase {
    func testControlLettersNormalizeFromC0Bytes() {
        XCTAssertEqual(ControlKeyNormalizer.normalizedKey(from: "\u{01}", controlPressed: true), "a")
        XCTAssertEqual(ControlKeyNormalizer.normalizedKey(from: "\u{02}", controlPressed: true), "b")
        XCTAssertEqual(ControlKeyNormalizer.normalizedKey(from: "\u{1A}", controlPressed: true), "z")
    }

    func testNonControlInputIsPreserved() {
        XCTAssertEqual(ControlKeyNormalizer.normalizedKey(from: "\u{01}", controlPressed: false), "\u{01}")
        XCTAssertEqual(ControlKeyNormalizer.normalizedKey(from: "a", controlPressed: true), "a")
        XCTAssertEqual(ControlKeyNormalizer.normalizedKey(from: "\u{1B}", controlPressed: true), "\u{1B}")
    }
}
