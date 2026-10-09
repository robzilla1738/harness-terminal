import Foundation

/// A transmitted Kitty image: its frames, and how far its animation has played. The first frame
/// is the root the transmit sent. Animation frames (`a=f`) are whole canvases the root's size,
/// composed when they arrive, so showing one is a lookup.
struct KittyImage: Codable {
    /// One frame. `textureID` names its pixels to the renderer and changes whenever they do;
    /// `gap` is how long it shows, in milliseconds (0: playback skips it).
    struct Frame: Codable {
        var image: DecodedImage
        var gap: Int
        var textureID: Int
    }

    /// `s=1`, `s=2`, `s=3`.
    enum Playback: String, Codable { case stopped, loading, running }

    static let defaultGap = 40

    let id: Int
    var frames: [Frame]
    var playback = Playback.stopped
    /// Loops to play before stopping; 0 loops forever.
    var maxLoops = 0
    var loops = 0
    var current = 0
    /// When the current frame first showed (uptime nanoseconds); nil until playback draws it.
    var shownAt: UInt64?

    init(id: Int, image: DecodedImage, textureID: Int) {
        self.id = id
        frames = [Frame(image: image, gap: 0, textureID: textureID)]
    }

    var currentFrame: Frame { frames[current] }
    var byteCount: Int { frames.count * frames[0].image.byteCount }

    /// Whether playback has frames left to show. Kitty advances only such images.
    var isAnimating: Bool {
        playback != .stopped && frames.count > 1 && frames.contains { $0.gap > 0 }
            && (maxLoops == 0 || loops < maxLoops)
    }

    /// Whether an `a=f` naming frame `number` adds a frame: 0 or past the last one does.
    func addsFrame(_ number: Int) -> Bool { index(number) == nil }

    /// `a=f`: lays `data` at (`x`, `y`) over a canvas — frame `r` when editing it, else base frame
    /// `c`, else the `Y` color — and keeps the result as frame `r` or a new last frame. Returns the
    /// error to report, or nil.
    mutating func loadFrame(_ data: DecodedImage, _ command: KittyGraphicsCommand, textureID: Int) -> String? {
        let root = frames[0].image
        // Data that hangs past the image's edge is clipped; data larger than it, or starting
        // outside it, is refused.
        guard data.pixelWidth <= root.pixelWidth, data.pixelHeight <= root.pixelHeight,
              (0 ..< root.pixelWidth).contains(command.x), (0 ..< root.pixelHeight).contains(command.y)
        else { return "EINVAL:the frame does not fit the image" }
        let edited = index(command.frameNumber)
        var canvas: DecodedImage
        if let edited {
            canvas = frames[edited].image
        } else if command.otherFrameNumber != 0 {
            guard let base = index(command.otherFrameNumber) else {
                return "EINVAL:no frame number \(command.otherFrameNumber)"
            }
            canvas = frames[base].image
        } else {
            canvas = Self.filled(width: root.pixelWidth, height: root.pixelHeight, color: command.backgroundColor)
        }
        Self.draw(data, from: (0, 0), width: data.pixelWidth, height: data.pixelHeight,
                  onto: &canvas, at: (command.x, command.y), overwriting: command.overwrites)
        // `z`: a positive gap, a negative one for a frame playback skips, or 0 for the default.
        if let edited {
            frames[edited].image = canvas
            frames[edited].textureID = textureID
            if command.z != 0 { frames[edited].gap = max(command.z, 0) }
        } else {
            let gap = command.z > 0 ? command.z : command.z < 0 ? 0 : Self.defaultGap
            frames.append(Frame(image: canvas, gap: gap, textureID: textureID))
        }
        return nil
    }

    /// `a=c`: lays a `w`×`h` rectangle of frame `r`, from (`X`, `Y`), onto frame `c` at (`x`, `y`).
    /// Returns the error to report, or nil.
    mutating func compose(_ command: KittyGraphicsCommand, textureID: Int) -> String? {
        guard let source = index(command.frameNumber) else { return "ENOENT:no source frame number \(command.frameNumber)" }
        guard let target = index(command.otherFrameNumber) else {
            return "ENOENT:no destination frame number \(command.otherFrameNumber)"
        }
        let imageWidth = frames[0].image.pixelWidth, imageHeight = frames[0].image.pixelHeight
        let width = command.width > 0 ? command.width : imageWidth
        let height = command.height > 0 ? command.height : imageHeight
        func fits(_ x: Int, _ y: Int) -> Bool { // subtracting, so hostile offsets can't overflow
            x >= 0 && y >= 0 && x <= imageWidth - width && y <= imageHeight - height
        }
        guard fits(command.sourceX, command.sourceY) else { return "EINVAL:the source rectangle is out of bounds" }
        guard fits(command.x, command.y) else { return "EINVAL:the destination rectangle is out of bounds" }
        if source == target, abs(command.sourceX - command.x) < width, abs(command.sourceY - command.y) < height {
            return "EINVAL:the source and destination rectangles overlap"
        }
        Self.draw(frames[source].image, from: (command.sourceX, command.sourceY), width: width, height: height,
                  onto: &frames[target].image, at: (command.x, command.y), overwriting: command.overwrites)
        frames[target].textureID = textureID
        return nil
    }

    /// `a=a`: retime frame `r` (with `z`), show frame `c`, then set the state and the loop count.
    mutating func control(_ command: KittyGraphicsCommand) {
        if let frame = index(command.frameNumber), command.z != 0 { frames[frame].gap = max(command.z, 0) }
        if let frame = index(command.otherFrameNumber), frame != current {
            current = frame
            shownAt = nil
        }
        switch command.animationState {
        case 1:
            playback = .stopped
            loops = 0
        case 2, 3:
            if playback == .stopped { shownAt = nil }
            playback = command.animationState == 2 ? .loading : .running
        default:
            break
        }
        if command.loopCount > 0 { maxLoops = command.loopCount - 1 }
    }

    /// `a=d,d=f`: removes frame `r`, or the last frame when `r` is past it, as Kitty does (an
    /// absent `r` names the root, and frame 2 takes its place). An image's only frame stays.
    mutating func deleteFrame(_ number: Int) {
        guard frames.count > 1 else { return }
        let removed = min(max(number, 1), frames.count) - 1
        frames.remove(at: removed)
        if removed < current {
            current -= 1
        } else if removed == current {
            current = min(current, frames.count - 1)
            shownAt = nil
        }
    }

    /// Kitty's playback step, for an image that `isAnimating`: once the current frame's gap has
    /// passed, move on to the next frame that has one. Wrapping around counts a loop; loading
    /// waits at the last frame for more instead. Returns when the frame after this one is due, or
    /// nil when there is nothing more to show for now.
    mutating func advance(now: UInt64) -> UInt64? {
        guard let shownAt else {
            self.shownAt = now
            return now + Self.nanoseconds(currentFrame.gap)
        }
        let due = shownAt + Self.nanoseconds(currentFrame.gap)
        guard now >= due else { return due }
        var next = current
        repeat {
            next = (next + 1) % frames.count
            if next == 0 {
                if playback == .loading { return nil }
                loops += 1
                if maxLoops > 0, loops >= maxLoops { return nil }
            }
        } while frames[next].gap == 0
        current = next
        self.shownAt = now
        return now + Self.nanoseconds(currentFrame.gap)
    }

    /// The index of frame `number` (1-based), if there is one.
    private func index(_ number: Int) -> Int? {
        number >= 1 && number <= frames.count ? number - 1 : nil
    }

    /// A gap in nanoseconds, capped at Kitty's 32-bit milliseconds so a hostile gap can't overflow.
    private static func nanoseconds(_ milliseconds: Int) -> UInt64 {
        UInt64(min(milliseconds, Int(Int32.max))) * 1_000_000
    }

    /// A canvas of one RGBA color (`0xRRGGBBAA`).
    private static func filled(width: Int, height: Int, color: UInt32) -> DecodedImage {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        if color != 0 {
            let pixel = [UInt8(color >> 24), UInt8(color >> 16 & 0xFF), UInt8(color >> 8 & 0xFF), UInt8(color & 0xFF)]
            for i in rgba.indices { rgba[i] = pixel[i & 3] }
        }
        return DecodedImage(rgba: rgba, pixelWidth: width, pixelHeight: height)
    }

    /// Lays `width`×`height` pixels of `source`, from `origin`, onto `canvas` at `target`: alpha
    /// blended ("over") unless `overwriting`. What falls outside the canvas is dropped.
    private static func draw(_ source: DecodedImage, from origin: (x: Int, y: Int), width: Int, height: Int,
                     onto canvas: inout DecodedImage, at target: (x: Int, y: Int), overwriting: Bool) {
        let columns = max(0, target.x) ..< min(canvas.pixelWidth, target.x + width)
        let rows = max(0, target.y) ..< min(canvas.pixelHeight, target.y + height)
        guard !columns.isEmpty, !rows.isEmpty else { return }
        let canvasWidth = canvas.pixelWidth
        source.rgba.withUnsafeBufferPointer { src in
            canvas.rgba.withUnsafeMutableBufferPointer { dst in
                for y in rows {
                    for x in columns {
                        let s = ((origin.y + y - target.y) * source.pixelWidth + origin.x + x - target.x) * 4
                        let d = (y * canvasWidth + x) * 4
                        let alpha = Int(src[s + 3])
                        if overwriting || alpha == 255 {
                            for c in 0 ..< 4 { dst[d + c] = src[s + c] }
                        } else if alpha > 0 {
                            // Both weights are in 1/255² units, so `total / 255` is the result's alpha.
                            let over = alpha * 255, under = Int(dst[d + 3]) * (255 - alpha)
                            let total = over + under
                            for c in 0 ..< 3 {
                                dst[d + c] = UInt8((Int(src[s + c]) * over + Int(dst[d + c]) * under) / total)
                            }
                            dst[d + 3] = UInt8((total + 127) / 255)
                        }
                    }
                }
            }
        }
    }
}
