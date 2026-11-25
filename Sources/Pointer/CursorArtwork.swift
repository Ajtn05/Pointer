import CoreGraphics
import Foundation
import ImageIO

struct CursorArtwork: Sendable {
    struct Step: Sendable {
        let frame: Int
        let duration: TimeInterval
    }

    let frames: [CGImage]
    let steps: [Step]
    let hotspot: CGPoint

    var width: Int { frames[0].width }
    var height: Int { frames[0].height }
    var duration: TimeInterval { steps.reduce(0) { $0 + $1.duration } }

    func frameIndex(at seconds: TimeInterval) -> Int {
        let position = seconds.truncatingRemainder(dividingBy: duration)
        var end = 0.0
        for step in steps {
            end += step.duration
            if position < end { return step.frame }
        }
        return steps[0].frame
    }

    func cursorFrames() -> (indices: [Int], delay: TimeInterval) {
        if steps.allSatisfy({ $0.frame == steps[0].frame }) {
            return ([steps[0].frame], 0)
        }

        // WindowServer plays up to 24 frames with a single delay. Repeat frames
        // when the source timings fit that grid and resample longer loops.
        for count in stride(from: steps.count, through: 24, by: 1) {
            let delay = duration / Double(count)
            var elapsed = 0.0
            let fits = steps.dropLast().allSatisfy { step in
                elapsed += step.duration
                let tick = elapsed / delay
                return abs(tick - tick.rounded()) < 0.0001
            }
            if fits { return (sample(count: count, delay: delay), delay) }
        }
        let delay = duration / 24
        return (sample(count: 24, delay: delay), delay)
    }

    private func sample(count: Int, delay: TimeInterval) -> [Int] {
        (0..<count).map { frameIndex(at: (Double($0) + 0.5) * delay) }
    }

    static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

enum ArtworkError: LocalizedError {
    case unsupported, invalidGIF, invalidANI, tooLarge

    var errorDescription: String? {
        switch self {
        case .unsupported: "Choose a .gif or .ani cursor file."
        case .invalidGIF: "This GIF could not be decoded."
        case .invalidANI: "This ANI file does not contain a supported cursor animation."
        case .tooLarge: "Choose a file under 24 MB with at most 512 frames and dimensions up to 4096 pixels."
        }
    }
}

enum ArtworkDecoder {
    static let maxFileSize = 24 * 1024 * 1024
    static let maxFrames = 512

    static func load(_ url: URL) throws -> (Data, CursorArtwork) {
        guard url.isFileURL else { throw ArtworkError.unsupported }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw ArtworkError.unsupported }
        guard values.fileSize ?? 0 <= maxFileSize else { throw ArtworkError.tooLarge }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maxFileSize + 1) ?? Data()
        return (data, try decode(data, filename: url.lastPathComponent))
    }

    static func decode(_ data: Data, filename: String) throws -> CursorArtwork {
        guard data.count <= maxFileSize else { throw ArtworkError.tooLarge }
        switch (filename as NSString).pathExtension.lowercased() {
        case "gif": return try gif(data)
        case "ani": return try ANIReader.decode(data)
        default: throw ArtworkError.unsupported
        }
    }

    private static func gif(_ data: Data) throws -> CursorArtwork {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "com.compuserve.gif" else {
            throw ArtworkError.invalidGIF
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw ArtworkError.invalidGIF }
        guard count <= maxFrames else { throw ArtworkError.tooLarge }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 192,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary

        var frames: [CGImage] = []
        var steps: [CursorArtwork.Step] = []
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
            guard width <= 4096, height <= 4096 else { throw ArtworkError.tooLarge }
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options),
                  CGImageSourceGetStatusAtIndex(source, index) == .statusComplete,
                  frames.first.map({ $0.width == frame.width && $0.height == frame.height }) ?? true else {
                throw ArtworkError.invalidGIF
            }
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
            let duration = delay.isFinite && delay > 0 ? max(delay, 0.01) : 0.1
            frames.append(frame)
            steps.append(.init(frame: index, duration: duration))
        }
        return CursorArtwork(frames: frames, steps: steps, hotspot: .zero)
    }
}
