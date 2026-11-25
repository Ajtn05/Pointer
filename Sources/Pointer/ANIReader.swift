import CoreGraphics
import Foundation
import ImageIO

enum ANIReader {
    private struct Frame {
        let image: CGImage
        let x: Int
        let y: Int
    }

    static func decode(_ data: Data) throws -> CursorArtwork {
        guard data.count >= 12, data.tag(at: 0) == "RIFF", data.tag(at: 8) == "ACON" else {
            throw ArtworkError.invalidANI
        }
        let declaredSize = data.le32(at: 4)
        // Some ANI encoders store the full file size, including the RIFF header.
        let end = declaredSize == data.count ? data.count : 8 + declaredSize
        guard end >= 12, end <= data.count else { throw ArtworkError.invalidANI }

        var header: Range<Int>?
        var icons: [Range<Int>] = []
        var sequence: [Int] = []
        var rates: [Int] = []
        try walk(data, range: 12..<end) { tag, body in
            switch tag {
            case "anih": header = body
            case "seq ": sequence = try table(data, body: body)
            case "rate": rates = try table(data, body: body)
            case "LIST" where body.count >= 4 && data.tag(at: body.lowerBound) == "fram":
                try walk(data, range: (body.lowerBound + 4)..<body.upperBound) { tag, frame in
                    guard tag == "icon" else { return }
                    guard icons.count < ArtworkDecoder.maxFrames else { throw ArtworkError.tooLarge }
                    icons.append(frame)
                }
            default: break
            }
        }

        guard let header, header.count >= 36, data.le32(at: header.lowerBound) >= 36 else {
            throw ArtworkError.invalidANI
        }

        let base = header.lowerBound
        let frameCount = data.le32(at: base + 4)
        let stepCount = data.le32(at: base + 8)
        let width = data.le32(at: base + 12)
        let height = data.le32(at: base + 16)
        let defaultRate = data.le32(at: base + 28)
        let flags = data.le32(at: base + 32)
        guard frameCount > 0, frameCount == icons.count, stepCount > 0, flags & 1 != 0 else {
            throw ArtworkError.invalidANI
        }
        guard stepCount <= ArtworkDecoder.maxFrames else { throw ArtworkError.tooLarge }

        let usesSequence = flags & 2 != 0
        guard !usesSequence || sequence.count >= stepCount else { throw ArtworkError.invalidANI }
        let steps = try (0..<stepCount).map { index -> CursorArtwork.Step in
            let frame = usesSequence ? sequence[index] : index % frameCount
            guard frame < frameCount else { throw ArtworkError.invalidANI }
            let rate = index < rates.count && rates[index] != 0 ? rates[index] : defaultRate
            return .init(frame: frame, duration: Double(rate == 0 ? 6 : rate) / 60)
        }

        let frames = try icons.map { try icon(data.subdata(in: $0), width: width, height: height) }
        return try align(frames, steps: steps)
    }

    private static func table(_ data: Data, body: Range<Int>) throws -> [Int] {
        guard body.count.isMultiple(of: 4) else { throw ArtworkError.invalidANI }
        guard body.count / 4 <= ArtworkDecoder.maxFrames else { throw ArtworkError.tooLarge }
        return stride(from: body.lowerBound, to: body.upperBound, by: 4).map { data.le32(at: $0) }
    }

    private static func walk(_ data: Data, range: Range<Int>, visit: (String, Range<Int>) throws -> Void) throws {
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            guard range.upperBound - cursor >= 8 else { throw ArtworkError.invalidANI }
            let length = data.le32(at: cursor + 4)
            let start = cursor + 8
            let end = start + length
            let next = end + length % 2
            guard next <= range.upperBound else { throw ArtworkError.invalidANI }
            try visit(data.tag(at: cursor), start..<end)
            cursor = next
        }
    }

    private static func icon(_ data: Data, width: Int, height: Int) throws -> Frame {
        guard data.count >= 6, data.le16(at: 0) == 0 else { throw ArtworkError.invalidANI }
        let type = data.le16(at: 2)
        let count = data.le16(at: 4)
        let directoryEnd = 6 + count * 16
        guard (type == 1 || type == 2), (1...256).contains(count), directoryEnd <= data.count else {
            throw ArtworkError.invalidANI
        }

        let entries = (0..<count).map { index in
            let entry = 6 + 16 * index
            let w = data[entry] == 0 ? 256 : Int(data[entry])
            let h = data[entry + 1] == 0 ? 256 : Int(data[entry + 1])
            return (entry: entry, width: w, height: h)
        }.sorted {
            let firstMatches = $0.width == width && $0.height == height
            let secondMatches = $1.width == width && $1.height == height
            if firstMatches != secondMatches { return firstMatches }
            return $0.width * $0.height > $1.width * $1.height
        }

        for (entry, w, h) in entries {
            let length = data.le32(at: entry + 8)
            let offset = data.le32(at: entry + 12)
            guard offset >= directoryEnd, length >= 8, offset + length <= data.count else { continue }
            let payload = data.subdata(in: offset..<(offset + length))
            guard let image = image(payload, directory: data, entry: entry, width: w, height: h) else { continue }
            let x = type == 2 ? min(data.le16(at: entry + 4), image.width - 1) : 0
            let y = type == 2 ? min(data.le16(at: entry + 6), image.height - 1) : 0
            return Frame(image: image, x: x, y: y)
        }
        throw ArtworkError.invalidANI
    }

    private static func image(_ payload: Data, directory: Data, entry: Int, width: Int, height: Int) -> CGImage? {
        let png: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        let imageData: Data
        if payload.starts(with: png) {
            imageData = payload
        } else {
            // CUR and ICO share the same bitmap payload. Rebuild a one-entry ICO
            // directory with the planes and bit depth in place of the CUR hotspot.
            let headerSize = payload.le32(at: 0)
            let planes: Int
            let depth: Int
            let bitmapWidth: Int
            let bitmapHeight: Int
            let compression: Int
            let colorsUsed: Int
            switch headerSize {
            case 12 where payload.count >= 12:
                planes = payload.le16(at: 8)
                depth = payload.le16(at: 10)
                bitmapWidth = payload.le16(at: 4)
                bitmapHeight = payload.le16(at: 6)
                compression = 0
                colorsUsed = 0
            case 40...124 where payload.count >= headerSize:
                planes = payload.le16(at: 12)
                depth = payload.le16(at: 14)
                bitmapWidth = payload.signed32(at: 4)
                bitmapHeight = payload.signed32(at: 8)
                compression = payload.le32(at: 16)
                colorsUsed = payload.le32(at: 32)
            default:
                return nil
            }
            guard planes == 1, bitmapWidth == width, abs(bitmapHeight) == height * 2
                    || (depth == 32 && abs(bitmapHeight) == height) else { return nil }
            if compression == 0, [1, 4, 8, 16, 24, 32].contains(depth) {
                return bitmap(payload, headerSize: headerSize, width: width, height: height,
                              depth: depth, colorsUsed: colorsUsed, topDown: bitmapHeight < 0)
            }

            var ico = Data([0, 0, 1, 0, 1, 0])
            ico.append(directory.subdata(in: entry..<(entry + 4)))
            ico.append(contentsOf: [UInt8(truncatingIfNeeded: planes), UInt8(truncatingIfNeeded: planes >> 8),
                                    UInt8(truncatingIfNeeded: depth), UInt8(truncatingIfNeeded: depth >> 8)])
            ico.append(directory.subdata(in: (entry + 8)..<(entry + 12)))
            ico.append(contentsOf: [22, 0, 0, 0])
            ico.append(payload)
            imageData = ico
        }
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == width,
              properties[kCGImagePropertyPixelHeight] as? Int == height else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func bitmap(_ payload: Data, headerSize: Int, width: Int, height: Int,
                               depth: Int, colorsUsed: Int, topDown: Bool) -> CGImage? {
        let maxColors = depth <= 8 ? 1 << depth : 0
        let paletteCount = colorsUsed == 0 ? maxColors : colorsUsed
        guard paletteCount <= (maxColors == 0 ? 256 : maxColors) else { return nil }
        let paletteEntrySize = headerSize == 12 ? 3 : 4

        // Both planes are padded to a four-byte row boundary. The optional
        // one-bit AND mask supplies transparency for legacy cursors.
        let stride = ((width * depth + 31) / 32) * 4
        let maskStride = ((width + 31) / 32) * 4
        let pixels = headerSize + paletteCount * paletteEntrySize
        let mask = pixels + stride * height
        guard mask <= payload.count else { return nil }
        let hasMask = mask + maskStride * height <= payload.count
        let hasAlpha = depth == 32 && (0..<(width * height)).contains { index in
            let offset = pixels + (index / width) * stride + (index % width) * 4
            return payload[offset + 3] != 0
        }
        var rgba = Data(count: width * height * 4)
        for y in 0..<height {
            let row = topDown ? y : height - y - 1
            let start = pixels + row * stride
            for x in 0..<width {
                let offset = start + x * depth / 8
                let destination = (y * width + x) * 4
                let blue: UInt8
                let green: UInt8
                let red: UInt8

                switch depth {
                case 1, 4, 8:
                    let shift = 8 - depth - (x * depth) % 8
                    let color = (Int(payload[offset]) >> shift) & (maxColors - 1)
                    guard color < paletteCount else { return nil }
                    let entry = headerSize + color * paletteEntrySize
                    blue = payload[entry]
                    green = payload[entry + 1]
                    red = payload[entry + 2]
                case 16:
                    let value = payload.le16(at: offset)
                    blue = UInt8((value & 31) * 255 / 31)
                    green = UInt8(((value >> 5) & 31) * 255 / 31)
                    red = UInt8(((value >> 10) & 31) * 255 / 31)
                default:
                    blue = payload[offset]
                    green = payload[offset + 1]
                    red = payload[offset + 2]
                }

                let transparent = hasMask && payload[mask + row * maskStride + x / 8] & (128 >> (x % 8)) != 0
                rgba[destination] = red
                rgba[destination + 1] = green
                rgba[destination + 2] = blue
                rgba[destination + 3] = hasAlpha ? payload[offset + 3] : (transparent ? 0 : 255)
            }
        }
        guard let provider = CGDataProvider(data: rgba as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func align(_ frames: [Frame], steps: [CursorArtwork.Step]) throws -> CursorArtwork {
        let x = frames.map(\.x).max()!
        let y = frames.map(\.y).max()!
        let width = x + frames.map { $0.image.width - $0.x }.max()!
        let height = y + frames.map { $0.image.height - $0.y }.max()!
        let images = try frames.map { frame -> CGImage in
            if frame.image.width == width, frame.image.height == height { return frame.image }
            guard let context = CursorArtwork.context(width: width, height: height) else {
                throw ArtworkError.invalidANI
            }
            let rect = CGRect(x: x - frame.x, y: height - (y - frame.y) - frame.image.height,
                              width: frame.image.width, height: frame.image.height)
            context.draw(frame.image, in: rect)
            guard let image = context.makeImage() else { throw ArtworkError.invalidANI }
            return image
        }
        return CursorArtwork(frames: images, steps: steps,
                             hotspot: CGPoint(x: Double(x) / Double(width), y: Double(y) / Double(height)))
    }
}

private extension Data {
    func tag(at offset: Int) -> String {
        String(decoding: self[offset..<(offset + 4)], as: UTF8.self)
    }

    func le16(at offset: Int) -> Int {
        Int(self[offset]) | Int(self[offset + 1]) << 8
    }

    func le32(at offset: Int) -> Int {
        le16(at: offset) | le16(at: offset + 2) << 16
    }

    func signed32(at offset: Int) -> Int {
        Int(Int32(bitPattern: UInt32(le32(at: offset))))
    }
}
