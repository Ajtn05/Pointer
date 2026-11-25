import CoreGraphics
import Foundation

struct RenderedCursor {
    struct Representation {
        let sheet: CGImage
        let frames: [CGImage]
    }

    let size: CGSize
    let frameCount: Int
    let delay: TimeInterval
    let representations: [Representation]

    init(_ artwork: CursorArtwork, size: Int) throws {
        let ratio = Double(size) / Double(max(artwork.width, artwork.height))
        let width = max(1, Int((Double(artwork.width) * ratio).rounded()))
        let height = max(1, Int((Double(artwork.height) * ratio).rounded()))
        let samples = artwork.cursorFrames()

        self.size = CGSize(width: width, height: height)
        frameCount = samples.indices.count
        delay = samples.delay

        representations = try [1, 2].map { scale in
            let pixelsWide = width * scale
            let pixelsHigh = height * scale
            let count = samples.indices.count
            guard let context = CursorArtwork.context(width: pixelsWide, height: pixelsHigh * count) else {
                throw CursorError.rendering
            }

            // WindowServer takes one image per display scale. Its animation
            // frames are stacked vertically, starting at the top of each image.
            context.interpolationQuality = .high
            for (position, index) in samples.indices.enumerated() {
                let rect = CGRect(x: 0, y: (count - position - 1) * pixelsHigh, width: pixelsWide, height: pixelsHigh)
                context.draw(artwork.frames[index], in: rect)
            }
            guard let sheet = context.makeImage() else { throw CursorError.rendering }

            let frames = try (0..<count).map { index in
                let rect = CGRect(x: 0, y: index * pixelsHigh, width: pixelsWide, height: pixelsHigh)
                guard let frame = sheet.cropping(to: rect) else { throw CursorError.rendering }
                return frame
            }
            return Representation(sheet: sheet, frames: frames)
        }
    }

    func hotspot(at point: CGPoint) -> CGPoint {
        CGPoint(x: min(size.width - 1, point.x * size.width),
                y: min(size.height - 1, point.y * size.height))
    }

    func frameIndex(at seconds: TimeInterval) -> Int {
        guard frameCount > 1 else { return 0 }
        let position = seconds.truncatingRemainder(dividingBy: delay * Double(frameCount))
        return min(frameCount - 1, Int(position / delay))
    }
}
