import Foundation
import XCTest
@testable import HarnessTerminalEngine

/// Kitty graphics animation: frames (`a=f`), playback control (`a=a`), and composition (`a=c`),
/// fed as the escape sequences a program sends, and played through `animateImages` with an
/// explicit clock.
final class KittyAnimationTests: XCTestCase {
    private let red: [UInt8] = [255, 0, 0, 255]
    private let green: [UInt8] = [0, 255, 0, 255]
    private let blue: [UInt8] = [0, 0, 255, 255]
    private let white: [UInt8] = [255, 255, 255, 255]

    private func makeTerm() -> (TerminalEmulator, () -> [String]) {
        let term = TerminalEmulator(cols: 80, rows: 24)
        var responses: [String] = []
        term.onResponse = { responses.append(String(decoding: $0, as: UTF8.self)) }
        return (term, { responses })
    }

    private func apc(_ control: String, _ pixels: [UInt8] = []) -> String {
        "\u{1b}_G\(control)" + (pixels.isEmpty ? "" : ";" + Data(pixels).base64EncodedString()) + "\u{1b}\\"
    }

    /// Image 1, two pixels wide and red, placed at the cursor.
    private func placeRedImage(_ term: TerminalEmulator, _ extra: String = "") {
        term.feed(apc("a=T,f=32,s=2,v=1,i=1\(extra)", red + red))
    }

    /// A one-color frame over the whole image, `gap` ms long.
    private func addFrame(_ term: TerminalEmulator, _ color: [UInt8], _ keys: String = "") {
        term.feed(apc("a=f,i=1,f=32,s=2,v=1\(keys)", color + color))
    }

    /// The pixels the screen's first image shows now.
    private func shown(_ term: TerminalEmulator, _ grid: TerminalGridSnapshot? = nil) -> [UInt8] {
        guard let id = (grid ?? term.readGrid()).images.first?.id, let image = term.image(for: id) else { return [] }
        return image.rgba
    }

    /// Plays the screen's animations at `ms`; returns the first pixel shown and the next deadline in ms.
    @discardableResult
    private func play(_ term: TerminalEmulator, at ms: UInt64) -> (pixel: [UInt8], next: UInt64?) {
        let (grid, next) = term.animateImages(in: term.readGrid(), now: ms * 1_000_000)
        return (Array(shown(term, grid).prefix(4)), next.map { $0 / 1_000_000 })
    }

    // MARK: Parsing

    func testAnimationKeysParse() throws {
        let frame = try XCTUnwrap(KittyGraphicsCommand.parse(Array("Ga=f,i=3,r=2,c=1,x=4,y=5,X=1,Y=4278190335,z=-1".utf8)))
        XCTAssertEqual(frame.action, "f")
        XCTAssertEqual(frame.frameNumber, 2)
        XCTAssertEqual(frame.otherFrameNumber, 1)
        XCTAssertEqual(frame.x, 4)
        XCTAssertEqual(frame.y, 5)
        XCTAssertTrue(frame.overwrites, "a=f overwrites with X=1")
        XCTAssertEqual(frame.backgroundColor, 0xFF00_00FF)
        XCTAssertEqual(frame.z, -1)

        let compose = try XCTUnwrap(KittyGraphicsCommand.parse(Array("Ga=c,i=3,r=1,c=2,X=1,Y=2,w=3,h=4,C=1".utf8)))
        XCTAssertEqual(compose.sourceX, 1)
        XCTAssertEqual(compose.sourceY, 2)
        XCTAssertEqual(compose.width, 3)
        XCTAssertEqual(compose.height, 4)
        XCTAssertTrue(compose.overwrites, "a=c overwrites with C=1, not X")

        let control = try XCTUnwrap(KittyGraphicsCommand.parse(Array("Ga=a,i=3,s=3,v=2".utf8)))
        XCTAssertEqual(control.animationState, 3)
        XCTAssertEqual(control.loopCount, 2)
    }

    // MARK: Frames

    func testFramesComposeOverABaseFrameOrTheBackgroundColor() {
        let (term, responses) = makeTerm()
        placeRedImage(term)
        // Frame 2: one green pixel at x=1 over frame 1. Frame 3: one blue pixel on a white canvas.
        term.feed(apc("a=f,i=1,f=32,s=1,v=1,x=1,c=1", green))
        term.feed(apc("a=f,i=1,f=32,s=1,v=1,Y=4294967295", blue))
        XCTAssertEqual(responses(), Array(repeating: "\u{1b}_Gi=1;OK\u{1b}\\", count: 3))
        XCTAssertEqual(shown(term), red + red, "the root frame shows until playback moves on")

        term.feed(apc("a=a,i=1,c=2"))
        XCTAssertEqual(shown(term), red + green)
        term.feed(apc("a=a,i=1,c=3"))
        XCTAssertEqual(shown(term), blue + white)
        // Without a base frame or `Y`, a frame starts transparent.
        term.feed(apc("a=f,i=1,f=32,s=1,v=1,x=1", green))
        term.feed(apc("a=a,i=1,c=4"))
        XCTAssertEqual(shown(term), [0, 0, 0, 0] + green)
        XCTAssertEqual(responses().count, 4, "animation control answers only errors")
    }

    func testEditingAFrameReplacesItsPixelsUnderANewTexture() {
        let (term, _) = makeTerm()
        placeRedImage(term)
        addFrame(term, blue)
        term.feed(apc("a=a,i=1,c=2"))
        let before = term.readGrid().images[0].id
        term.feed(apc("a=f,i=1,r=2,f=32,s=1,v=1", green))
        XCTAssertEqual(shown(term), green + blue, "r=2 draws over frame 2 itself")
        XCTAssertNotEqual(term.readGrid().images[0].id, before, "changed pixels get a new texture id")
        XCTAssertNil(term.image(for: before))

        // r=1 edits the root frame, which every placement of the image shows.
        term.feed(apc("a=f,i=1,r=1,X=1,f=32,s=1,v=1,x=1", [0, 0, 0, 0]))
        term.feed(apc("a=a,i=1,c=1"))
        XCTAssertEqual(shown(term), red + [0, 0, 0, 0], "X=1 replaces rather than blends")
    }

    func testAlphaBlendsUnlessOverwriting() {
        let (term, _) = makeTerm()
        placeRedImage(term)
        term.feed(apc("a=f,i=1,c=1,f=32,s=1,v=1", [0, 0, 255, 128]))
        term.feed(apc("a=a,i=1,c=2"))
        XCTAssertEqual(shown(term), [127, 0, 128, 255] + red, "half-transparent blue over red")
    }

    func testChunkedFrameWithContinuationKeysOnly() {
        let (term, responses) = makeTerm()
        placeRedImage(term)
        let data = Data(blue + green).base64EncodedString()
        let half = data.index(data.startIndex, offsetBy: 4)
        term.feed("\u{1b}_Ga=f,i=1,f=32,s=2,v=1,m=1;\(data[..<half])\u{1b}\\")
        term.feed("\u{1b}_Gm=0;\(data[half...])\u{1b}\\")
        term.feed(apc("a=a,i=1,c=2"))
        XCTAssertEqual(shown(term), blue + green, "later chunks carry only m=, yet join the frame")
        XCTAssertEqual(responses().last, "\u{1b}_Gi=1;OK\u{1b}\\")
    }

    #if canImport(ImageIO)
    func testPNGFrame() {
        let (term, _) = makeTerm()
        placeRedImage(term)
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNg+M/wHwAEAQH/cetH5QAAAABJRU5ErkJggg=="
        term.feed("\u{1b}_Ga=f,i=1,f=100,x=1,c=1;\(png)\u{1b}\\")
        term.feed(apc("a=a,i=1,c=2"))
        XCTAssertEqual(Array(shown(term).suffix(4)), green, "a PNG frame lands like a raw one")
    }
    #endif

    // MARK: Composition

    func testComposeCopiesARectangleBetweenFrames() {
        let (term, responses) = makeTerm()
        placeRedImage(term)
        addFrame(term, blue)
        term.feed(apc("a=f,i=1,r=2,f=32,s=1,v=1", green)) // frame 2: green, blue
        term.feed(apc("a=c,i=1,r=2,c=1,X=1,w=1,h=1"))
        term.feed(apc("a=a,i=1,c=1"))
        XCTAssertEqual(shown(term), blue + red, "frame 2's (1,0) pixel lands at frame 1's (0,0)")
        XCTAssertEqual(responses().last, "\u{1b}_Gi=1;OK\u{1b}\\")
    }

    func testComposeErrors() {
        let (term, responses) = makeTerm()
        placeRedImage(term)
        addFrame(term, blue)
        let cases = [
            ("a=c,i=1,r=3,c=1", "ENOENT"),          // no source frame
            ("a=c,i=1,r=1", "ENOENT"),              // no destination frame
            ("a=c,i=1,r=1,c=2,X=1", "EINVAL"),      // source runs past the edge
            ("a=c,i=1,r=1,c=2,x=2,w=1", "EINVAL"),  // destination runs past the edge
            ("a=c,i=1,r=1,c=1,w=1", "EINVAL"),      // same frame, overlapping
            ("a=c,i=9,r=1,c=2", "ENOENT"),          // no such image
        ]
        for (control, code) in cases {
            term.feed(apc(control))
            XCTAssertTrue(responses().last?.contains(code) == true, "\(control) → \(code), got \(responses().last ?? "")")
        }
        term.feed(apc("a=c,i=1,r=1,c=1,X=1,w=1,h=1"))
        XCTAssertEqual(responses().last, "\u{1b}_Gi=1;OK\u{1b}\\", "disjoint rectangles of one frame compose")
    }

    // MARK: Errors and quietness

    func testFrameErrorsRespectQuietness() {
        let (term, responses) = makeTerm()
        term.feed(apc("a=f,i=4,f=32,s=1,v=1", blue))
        XCTAssertTrue(responses().last?.hasPrefix("\u{1b}_Gi=4;ENOENT") == true, "no image to add a frame to")
        placeRedImage(term)
        term.feed(apc("a=f,i=1,c=7,f=32,s=1,v=1", blue))
        XCTAssertTrue(responses().last?.hasPrefix("\u{1b}_Gi=1;EINVAL") == true, "no base frame 7")
        term.feed(apc("a=f,i=1,f=32,s=3,v=1", blue + blue + blue))
        XCTAssertTrue(responses().last?.hasPrefix("\u{1b}_Gi=1;EINVAL") == true, "frame wider than the image")
        term.feed(apc("a=a,i=5,s=3"))
        XCTAssertTrue(responses().last?.hasPrefix("\u{1b}_Gi=5;ENOENT") == true)

        let count = responses().count
        term.feed(apc("a=f,i=1,q=1,f=32,s=1,v=1", blue))
        term.feed(apc("a=f,i=4,q=2,f=32,s=1,v=1", blue))
        XCTAssertEqual(responses().count, count, "q=1 hides OK, q=2 hides errors too")
        term.feed(apc("a=f,i=4,q=1,f=32,s=1,v=1", blue))
        XCTAssertEqual(responses().count, count + 1, "q=1 still reports errors")
    }

    func testHostileOffsetsAndGapsAreRefusedOrCapped() {
        let (term, responses) = makeTerm()
        placeRedImage(term)
        let huge = Int.max
        term.feed(apc("a=f,i=1,x=\(huge),f=32,s=1,v=1", blue))
        XCTAssertTrue(responses().last?.hasPrefix("\u{1b}_Gi=1;EINVAL") == true, "a corner past the image")
        term.feed(apc("a=f,i=1,x=-1,f=32,s=1,v=1", blue))
        XCTAssertTrue(responses().last?.hasPrefix("\u{1b}_Gi=1;EINVAL") == true, "a corner before it")
        addFrame(term, blue, ",z=\(huge)")
        term.feed(apc("a=c,i=1,r=1,c=2,X=\(huge),w=1"))
        XCTAssertTrue(responses().last?.hasPrefix("\u{1b}_Gi=1;EINVAL") == true)
        term.feed(apc("a=a,i=1,s=3"))
        play(term, at: 0)
        XCTAssertEqual(play(term, at: 0).next, UInt64(Int32.max), "the gap is capped at 2^31 ms")
    }

    // MARK: Playback

    func testPlaybackFollowsGapsAndLoops() {
        let (term, _) = makeTerm()
        placeRedImage(term)
        addFrame(term, blue, ",z=100")
        addFrame(term, green, ",z=50")
        XCTAssertNil(play(term, at: 0).next, "stopped: nothing to schedule")
        term.feed(apc("a=a,i=1,s=3"))
        XCTAssertEqual(play(term, at: 1000).next, 1000, "the root frame has no gap, so it moves on at once")
        XCTAssertEqual(play(term, at: 1000).pixel, blue)
        XCTAssertEqual(play(term, at: 1050).next, 1100, "frame 2 shows for its 100 ms")
        XCTAssertEqual(play(term, at: 1050).pixel, blue)
        XCTAssertEqual(play(term, at: 1100).pixel, green)
        let wrapped = play(term, at: 1150)
        XCTAssertEqual(wrapped.pixel, blue, "looping skips the gapless root frame")
        XCTAssertEqual(wrapped.next, 1250)
    }

    func testLoopCountStopsAtTheLastFrame() {
        let (term, _) = makeTerm()
        placeRedImage(term)
        term.feed(apc("a=a,i=1,r=1,z=10")) // the root frame needs a gap set by control
        addFrame(term, blue, ",z=10")
        term.feed(apc("a=a,i=1,s=3,v=2")) // v=2: play once
        play(term, at: 0)
        XCTAssertEqual(play(term, at: 10).pixel, blue)
        let end = play(term, at: 20)
        XCTAssertEqual(end.pixel, blue, "the last frame stays up")
        XCTAssertNil(end.next, "nothing left to play")

        term.feed(apc("a=a,i=1,s=1"))
        term.feed(apc("a=a,i=1,c=1,s=3"))
        XCTAssertEqual(play(term, at: 100).pixel, red)
        XCTAssertEqual(play(term, at: 110).pixel, blue, "stopping reset the loop count, so it plays again")
    }

    func testLoadingWaitsAtTheLastFrameForMore() {
        let (term, _) = makeTerm()
        placeRedImage(term)
        addFrame(term, blue, ",z=10")
        term.feed(apc("a=a,i=1,s=2"))
        play(term, at: 0)
        XCTAssertEqual(play(term, at: 0).pixel, blue)
        let waiting = play(term, at: 10)
        XCTAssertEqual(waiting.pixel, blue, "loading does not wrap")
        XCTAssertNil(waiting.next)
        addFrame(term, green, ",z=10")
        XCTAssertEqual(play(term, at: 20).pixel, green, "a new frame resumes playback")
    }

    func testStopCurrentFrameAndRetiming() {
        let (term, _) = makeTerm()
        placeRedImage(term)
        addFrame(term, blue, ",z=10")
        addFrame(term, green, ",z=-1") // gapless: skipped, only a base for others
        addFrame(term, white, ",z=10")
        term.feed(apc("a=a,i=1,s=3,c=2"))
        XCTAssertEqual(play(term, at: 0).pixel, blue, "c=2 shows frame 2")
        XCTAssertEqual(play(term, at: 10).pixel, white, "the gapless frame is skipped")
        term.feed(apc("a=a,i=1,r=2,z=500"))
        play(term, at: 20)
        XCTAssertEqual(play(term, at: 20).pixel, blue)
        XCTAssertEqual(play(term, at: 30).next, 520, "frame 2 now shows for 500 ms")

        term.feed(apc("a=a,i=1,s=1"))
        let stopped = play(term, at: 1000)
        XCTAssertEqual(stopped.pixel, blue)
        XCTAssertNil(stopped.next)
    }

    func testOnlyDrawnImagesAdvance() {
        let (term, _) = makeTerm()
        placeRedImage(term)
        addFrame(term, blue, ",z=10")
        term.feed(apc("a=a,i=1,s=3"))
        term.feed(apc("a=d,d=i,i=1")) // lowercase: the image stays, its placement goes
        XCTAssertNil(play(term, at: 0).next, "nothing drawn, nothing scheduled")
        term.feed(apc("a=p,i=1"))
        XCTAssertEqual(shown(term), red + red, "the hidden animation held still")
        XCTAssertEqual(play(term, at: 100).next, 100)
    }

    func testPlaceholderCellsAnimate() {
        let (term, _) = makeTerm()
        term.feed(apc("a=T,U=1,f=32,s=2,v=1,i=7,c=1,r=1", red + red))
        term.feed(apc("a=f,i=7,f=32,s=2,v=1,z=10", blue + blue))
        term.feed(apc("a=a,i=7,s=3"))
        term.feed("\u{1b}[38;5;7m\u{10EEEE}\u{1b}[0m")
        XCTAssertEqual(shown(term), red + red)
        play(term, at: 0)
        XCTAssertEqual(play(term, at: 0).pixel, blue, "a placeholder slice shows the current frame")
    }

    // MARK: Memory

    func testFramesCountAgainstTheImageQuotaAndDeletingFreesThem() throws {
        let (term, responses) = makeTerm()
        let side = 2048 // 16 MiB a frame: four fill the 64 MiB budget
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("harness-kitty-anim-\(UUID().uuidString).rgba")
        try Data(count: side * side * 4).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let path = Data(file.path.utf8).base64EncodedString()
        term.feed(apc("a=t,f=32,s=1,v=1,i=2", red))
        term.feed("\u{1b}_Ga=t,t=f,f=32,s=\(side),v=\(side),i=1;\(path)\u{1b}\\")
        for _ in 0 ..< 3 { term.feed(apc("a=f,i=1,f=32,s=1,v=1", blue)) }
        XCTAssertEqual(responses().filter { $0 == "\u{1b}_Gi=1;OK\u{1b}\\" }.count, 4)
        term.feed(apc("a=p,i=2"))
        XCTAssertTrue(responses().last?.hasPrefix("\u{1b}_Gi=2;ENOENT") == true, "older images make room for frames")
        term.feed(apc("a=f,i=1,f=32,s=1,v=1", blue))
        XCTAssertTrue(responses().last?.hasPrefix("\u{1b}_Gi=1;ENOSPC") == true, "a fifth frame would not fit")
        term.feed(apc("a=f,i=1,r=4,f=32,s=1,v=1", green))
        XCTAssertEqual(responses().last, "\u{1b}_Gi=1;OK\u{1b}\\", "editing a frame needs no room")

        term.feed(apc("a=d,d=I,i=1"))
        term.feed(apc("a=t,f=32,s=1,v=1,i=3", red))
        term.feed("\u{1b}_Ga=t,t=f,f=32,s=\(side),v=\(side),i=4;\(path)\u{1b}\\")
        for _ in 0 ..< 2 { term.feed(apc("a=f,i=4,f=32,s=1,v=1", blue)) }
        term.feed(apc("a=p,i=3"))
        XCTAssertEqual(responses().last, "\u{1b}_Gi=3;OK\u{1b}\\", "the deleted image's frames freed their bytes")
    }
}
