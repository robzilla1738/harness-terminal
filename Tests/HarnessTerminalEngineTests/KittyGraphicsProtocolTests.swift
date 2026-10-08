import XCTest
import CHarnessBase64
@testable import HarnessTerminalEngine

/// Roadmap PR-14: the Kitty graphics protocol beyond display — ack (`OK`/error gated by quietness),
/// query (`a=q`), transmit-once / place-many (`a=t` then `a=p`, keyed by `i=`), and delete
/// (`a=d` all / by id). Animation has its own suite, `KittyAnimationTests`.
final class KittyGraphicsProtocolTests: XCTestCase {
    /// A 1×1 RGBA red pixel, base64 — the smallest valid `f=32,s=1,v=1` payload.
    private let pixel = "/wAA/w=="

    private func makeTerm() -> (TerminalEmulator, () -> [String]) {
        let term = TerminalEmulator(cols: 80, rows: 24)
        var responses: [String] = []
        term.onResponse = { responses.append(String(decoding: $0, as: UTF8.self)) }
        return (term, { responses })
    }

    private func placementCount(_ term: TerminalEmulator) -> Int { term.readGrid().images.count }

    func testTransmitAndDisplayAcksOKAndPlaces() {
        let (term, responses) = makeTerm()
        term.feed("\u{1b}_Ga=T,f=32,s=1,v=1,i=5;\(pixel)\u{1b}\\")
        XCTAssertEqual(placementCount(term), 1, "a=T places the image")
        XCTAssertTrue(responses().contains("\u{1b}_Gi=5;OK\u{1b}\\"), "transmit+display acks OK echoing i=5")
    }

    func testQueryAcksWithoutPlacing() {
        let (term, responses) = makeTerm()
        term.feed("\u{1b}_Ga=q,f=32,s=1,v=1,i=7;\(pixel)\u{1b}\\")
        XCTAssertEqual(placementCount(term), 0, "a=q never places — it's a capability probe")
        XCTAssertTrue(responses().contains("\u{1b}_Gi=7;OK\u{1b}\\"), "query acks OK so detection succeeds")
    }

    func testQueryFailureAcksErrorEvenWhenOKIsQuiet() {
        let (term, responses) = makeTerm()
        // s=2,v=2 needs 16 bytes but we send 4 → undecodable. q=1 suppresses OK but NOT errors.
        term.feed("\u{1b}_Ga=q,f=32,s=2,v=2,i=3,q=1;\(pixel)\u{1b}\\")
        let r = responses().joined()
        XCTAssertTrue(r.contains("\u{1b}_Gi=3;") && r.contains("EBADF"), "an error still reports under q=1")
    }

    func testQuietnessSuppressesAcks() {
        let (term, responses) = makeTerm()
        term.feed("\u{1b}_Ga=T,f=32,s=1,v=1,i=5,q=1;\(pixel)\u{1b}\\") // q=1 → no OK
        XCTAssertEqual(placementCount(term), 1)
        XCTAssertTrue(responses().isEmpty, "q=1 suppresses the OK ack")

        term.feed("\u{1b}_Ga=T,f=32,s=1,v=1,i=6,q=2;\(pixel)\u{1b}\\") // q=2 → nothing at all
        XCTAssertTrue(responses().isEmpty, "q=2 suppresses OK and errors")
    }

    func testNoIDMeansNoAck() {
        let (term, responses) = makeTerm()
        term.feed("\u{1b}_Ga=T,f=32,s=1,v=1;\(pixel)\u{1b}\\") // no i= / I= → unaddressable
        XCTAssertEqual(placementCount(term), 1, "still displays")
        XCTAssertTrue(responses().isEmpty, "no id/number → no addressable reply")
    }

    func testTransmitThenPlaceMany() {
        let (term, responses) = makeTerm()
        term.feed("\u{1b}_Ga=t,f=32,s=1,v=1,i=9;\(pixel)\u{1b}\\") // transmit only — no placement
        XCTAssertEqual(placementCount(term), 0, "a=t stores without placing")
        XCTAssertTrue(responses().contains("\u{1b}_Gi=9;OK\u{1b}\\"))

        term.feed("\u{1b}_Ga=p,i=9\u{1b}\\") // place it (no payload needed)
        term.feed("\u{1b}_Ga=p,i=9\u{1b}\\") // place it again — place-many
        XCTAssertEqual(placementCount(term), 2, "a=p re-uses the transmitted image each time")
    }

    func testPlaceUnknownIDErrors() {
        let (term, responses) = makeTerm()
        term.feed("\u{1b}_Ga=p,i=99\u{1b}\\")
        XCTAssertEqual(placementCount(term), 0)
        let r = responses().joined()
        XCTAssertTrue(r.contains("\u{1b}_Gi=99;") && r.contains("ENOENT"), "placing an untransmitted id errors")
    }

    func testDeleteAllRemovesEveryPlacement() {
        let (term, _) = makeTerm()
        term.feed("\u{1b}_Ga=T,f=32,s=1,v=1,i=1;\(pixel)\u{1b}\\")
        term.feed("\u{1b}_Ga=T,f=32,s=1,v=1,i=2;\(pixel)\u{1b}\\")
        XCTAssertEqual(placementCount(term), 2)
        term.feed("\u{1b}_Ga=d,d=a\u{1b}\\")
        XCTAssertEqual(placementCount(term), 0, "d=a clears all placements")
    }

    func testDeleteByIDRemovesOnlyThatImage() {
        let (term, _) = makeTerm()
        term.feed("\u{1b}_Ga=T,f=32,s=1,v=1,i=1;\(pixel)\u{1b}\\")
        term.feed("\u{1b}_Ga=T,f=32,s=1,v=1,i=2;\(pixel)\u{1b}\\")
        XCTAssertEqual(placementCount(term), 2)
        term.feed("\u{1b}_Ga=d,d=i,i=1\u{1b}\\")
        XCTAssertEqual(placementCount(term), 1, "d=i removes only the matching image id")
    }

    func testFileAndTempFileTransmission() throws {
        let (term, responses) = makeTerm()
        let pixelBytes = Data([0xFF, 0, 0, 0xFF])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("harness-kitty-\(UUID().uuidString).rgba")
        try pixelBytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let path = Data(file.path.utf8).base64EncodedString()
        term.feed("\u{1b}_Ga=T,t=f,f=32,s=1,v=1,i=3;\(path)\u{1b}\\")
        XCTAssertEqual(placementCount(term), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "t=f leaves the file")

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("tty-graphics-protocol-\(UUID().uuidString)")
        try pixelBytes.write(to: temp)
        term.feed("\u{1b}_Ga=T,t=t,f=32,s=1,v=1,i=4;\(Data(temp.path.utf8).base64EncodedString())\u{1b}\\")
        XCTAssertEqual(placementCount(term), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path), "t=t deletes the temp file once read")

        term.feed("\u{1b}_Ga=T,t=f,f=32,s=1,v=1,i=5;\(Data("/nonexistent/x".utf8).base64EncodedString())\u{1b}\\")
        XCTAssertTrue(responses().joined().contains("\u{1b}_Gi=5;EBADF"))
        term.feed("\u{1b}_Ga=T,t=x,f=32,s=1,v=1,i=6;AAAA\u{1b}\\")
        XCTAssertTrue(responses().joined().contains("\u{1b}_Gi=6;EINVAL"), "an unknown medium is refused")
    }

    func testATempPathThatEscapesTheTempFolderIsNotDeleted() throws {
        let (term, _) = makeTerm()
        let outside = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".harness-test-tty-graphics-protocol-\(UUID().uuidString)")
        try Data([0xFF, 0, 0, 0xFF]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let sneaky = "/tmp/../" + outside.path.dropFirst()
        term.feed("\u{1b}_Ga=T,t=t,f=32,s=1,v=1,i=7;\(Data(sneaky.utf8).base64EncodedString())\u{1b}\\")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "only files really in a temp folder are deleted")
    }

    func testImageNumbersGetAnIDAndDeleteByNumber() {
        let (term, _) = makeTerm()
        term.feed("\u{1b}_Ga=T,f=32,s=1,v=1,I=5;\(pixel)\u{1b}\\")
        term.feed("\u{1b}_Ga=T,f=32,s=1,v=1,i=5;\(pixel)\u{1b}\\")
        term.feed("\u{1b}_Ga=p,I=5\u{1b}\\")
        XCTAssertEqual(placementCount(term), 3, "a=p finds the image by its number")
        term.feed("\u{1b}_Ga=d,d=n,I=5\u{1b}\\")
        XCTAssertEqual(placementCount(term), 1, "d=n removes the numbered image, not id 5")
    }

    func testSharedMemoryTransmission() {
        let (term, _) = makeTerm()
        let name = "/hsm\(UInt32.random(in: 0 ... .max))"
        let bytes: [UInt8] = [0xFF, 0, 0, 0xFF]
        XCTAssertEqual(harness_shm_put(name, bytes, 4), 0)
        term.feed("\u{1b}_Ga=T,t=s,f=32,s=1,v=1,i=8;\(Data(name.utf8).base64EncodedString())\u{1b}\\")
        XCTAssertEqual(placementCount(term), 1)
        var leftover: UnsafeMutablePointer<UInt8>?
        XCTAssertEqual(harness_shm_take(name, 0, 0, 16, &leftover), -1, "the terminal unlinks the object")
    }

    func testUnicodePlaceholdersDrawSlicesOfAVirtualPlacement() {
        let (term, _) = makeTerm()
        XCTAssertEqual(KittyPlaceholders.diacritics.count, 297, "Kitty's row/column table")
        XCTAssertEqual(KittyPlaceholders.diacritics.prefix(3), [0x0305, 0x030D, 0x030E])
        // Transmit image 7 as a 2×2-cell virtual placement: nothing is drawn yet.
        term.feed("\u{1b}_Ga=T,U=1,f=32,s=1,v=1,i=7,c=2,r=2;\(pixel)\u{1b}\\")
        XCTAssertEqual(placementCount(term), 0)
        // Row 0: two cells, the first with row/column marks, the second continuing it. Row 1 names
        // its row and column explicitly. Foreground 7 (256-color) is the image id.
        let p = "\u{10EEEE}"
        term.feed("\u{1b}[38;5;7m\(p)\u{0305}\u{0305}\(p)\r\n\(p)\u{030D}\u{0305}\(p)\u{030D}\u{030D}\u{1b}[0m")
        let images = term.readGrid().images.sorted { ($0.row, $0.col) < ($1.row, $1.col) }
        XCTAssertEqual(images.count, 2, "each row's consecutive cells are one slice")
        XCTAssertEqual(images[0].cols, 2)
        XCTAssertEqual(images[0].sourceX, 0)
        XCTAssertEqual(images[0].sourceWidth, 1)
        XCTAssertEqual(images[0].sourceHeight, 0.5)
        XCTAssertEqual(images[1].row, 1)
        XCTAssertEqual(images[1].sourceY, 0.5)
        XCTAssertNotNil(term.image(for: images[0].id), "the slice's pixels come from the transmitted image")

        term.feed("\u{1b}_Ga=d,d=i,i=7\u{1b}\\")
        XCTAssertTrue(term.readGrid().images.isEmpty, "deleting the image removes its virtual placement")
    }

    /// An id above 2^24: the foreground carries its low 24 bits and a third mark its high byte.
    /// Without that mark, the one virtual placement whose low bits match is drawn.
    func testUnicodePlaceholdersResolveAnIDsHighByte() {
        let (term, _) = makeTerm()
        let id = 5 << 24 | 7
        term.feed("\u{1b}_Ga=T,U=1,f=32,s=1,v=1,i=\(id),c=2,r=2;\(pixel)\u{1b}\\")
        let p = "\u{10EEEE}", mark = { (i: Int) in String(Character(Unicode.Scalar(KittyPlaceholders.diacritics[i])!)) }
        // Row 0 names the high byte (the second cell inherits it); row 1 leaves it out.
        term.feed("\u{1b}[38;2;0;0;7m\(p)\(mark(0))\(mark(0))\(mark(5))\(p)\r\n\(p)\(mark(1))\(mark(0))\(p)\u{1b}[0m")
        var images = term.readGrid().images.sorted { $0.row < $1.row }
        XCTAssertEqual(images.map(\.row), [0, 1], "both rows draw image \(id)")
        XCTAssertEqual(images.map(\.cols), [2, 2])
        XCTAssertEqual(images[1].sourceY, 0.5)

        // A second image with the same low 24 bits: the row with the high byte still resolves,
        // the row without it is ambiguous and draws nothing.
        term.feed("\u{1b}_Ga=T,U=1,f=32,s=1,v=1,i=\(6 << 24 | 7),c=2,r=2;\(pixel)\u{1b}\\")
        images = term.readGrid().images
        XCTAssertEqual(images.map(\.row), [0])
        XCTAssertEqual(term.readGrid().cells[0].placeholderMark, UInt16(KittyPlaceholders.diacritics[5]))
    }

    /// Deleting by id range or by number takes virtual placements too, and the uppercase forms
    /// forget the image even when only a virtual placement held it.
    func testDeleteByRangeAndNumberRemovesVirtualPlacements() {
        let (term, responses) = makeTerm()
        let p = "\u{10EEEE}"
        term.feed("\u{1b}_Ga=T,U=1,f=32,s=1,v=1,i=3,c=1,r=1;\(pixel)\u{1b}\\")
        term.feed("\u{1b}[38;5;3m\(p)\u{1b}[0m")
        XCTAssertEqual(placementCount(term), 1)
        term.feed("\u{1b}_Ga=d,d=r,x=1,y=5\u{1b}\\")
        XCTAssertEqual(placementCount(term), 0, "d=r removes the virtual placement")
        term.feed("\u{1b}_Ga=p,U=1,i=3,c=1,r=1\u{1b}\\")
        XCTAssertEqual(placementCount(term), 1, "lowercase keeps the image")
        term.feed("\u{1b}_Ga=d,d=R,x=1,y=5\u{1b}\\")
        term.feed("\u{1b}_Ga=p,U=1,i=3,c=1,r=1\u{1b}\\")
        XCTAssertEqual(placementCount(term), 0, "d=R forgets it")
        XCTAssertTrue(responses().joined().contains("\u{1b}_Gi=3;ENOENT"))

        // An image number's id is 2^30 + n: its low 24 bits name it with no high-byte mark.
        term.feed("\u{1b}[2J\u{1b}[H\u{1b}_Ga=T,U=1,f=32,s=1,v=1,I=9,c=1,r=1;\(pixel)\u{1b}\\")
        term.feed("\u{1b}[38;5;1m\(p)\u{1b}[0m")
        XCTAssertEqual(placementCount(term), 1, "the numbered image's virtual placement draws")
        term.feed("\u{1b}_Ga=d,d=N,I=9\u{1b}\\")
        XCTAssertEqual(placementCount(term), 0, "d=N removes the virtual placement")
        term.feed("\u{1b}_Ga=p,U=1,I=9,c=1,r=1\u{1b}\\")
        XCTAssertTrue(responses().joined().contains("\u{1b}_GI=9;ENOENT"), "d=N forgets the image")
    }

    func testDeleteByPositionAndZAndLowercaseKeepsData() {
        let (term, _) = makeTerm()
        term.feed("\u{1b}_Ga=T,f=32,s=1,v=1,i=1,z=5;\(pixel)\u{1b}\\")   // row 1 (0-based 0)
        term.feed("\u{1b}_Ga=T,f=32,s=1,v=1,i=2;\(pixel)\u{1b}\\")       // row 2
        term.feed("\u{1b}_Ga=d,d=z,z=5\u{1b}\\")
        XCTAssertEqual(placementCount(term), 1, "d=z removes that z-index only")
        term.feed("\u{1b}_Ga=d,d=y,y=2\u{1b}\\")
        XCTAssertEqual(placementCount(term), 0, "d=y removes what covers that row")
        term.feed("\u{1b}_Ga=p,i=2\u{1b}\\")
        XCTAssertEqual(placementCount(term), 1, "lowercase delete keeps the transmitted image")
        term.feed("\u{1b}_Ga=d,d=I,i=2\u{1b}\\")
        term.feed("\u{1b}_Ga=p,i=2\u{1b}\\")
        XCTAssertEqual(placementCount(term), 0, "uppercase forgets it")
    }

    /// RIS (`ESC c`, full reset) must clear the transmitted-image cache, not just placements —
    /// otherwise transmit-once images survive a reset and keep occupying the per-screen byte
    /// budget. Regression for `fullReset()` clearing `kittyPending` but leaking `kittyTransmitted`.
    func testFullResetClearsTransmittedImageCache() {
        let (term, responses) = makeTerm()
        term.feed("\u{1b}_Ga=t,f=32,s=1,v=1,i=9;\(pixel)\u{1b}\\") // transmit (store) i=9
        term.feed("\u{1b}_Ga=p,i=9\u{1b}\\")                       // place it → succeeds
        XCTAssertEqual(placementCount(term), 1)

        term.feed("\u{1b}c") // RIS — full reset

        XCTAssertEqual(placementCount(term), 0, "RIS clears placements")
        term.feed("\u{1b}_Ga=p,i=9\u{1b}\\") // the cached image must be gone now
        let r = responses().joined()
        XCTAssertTrue(r.contains("\u{1b}_Gi=9;") && r.contains("ENOENT"),
                      "RIS must clear the transmitted-image cache, so placing i=9 afterward is not found")
    }
}
