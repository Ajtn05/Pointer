import CoreGraphics
import Foundation
import Testing
@testable import Pointer

@Test func animatedGIFPreservesFrameDelays() throws {
    let artwork = try load("cursor.gif")
    #expect(artwork.width == 32)
    #expect(artwork.height == 24)
    #expect(artwork.steps.map(\.duration) == [0.04, 0.12])
    #expect(artwork.cursorFrames().indices == [0, 1, 1, 1])
}

@Test func optimizedGIFCompositesPartialFrames() throws {
    let artwork = try load("optimized.gif")
    let frame = try #require(artwork.frames.last)
    #expect(pixel(frame, at: CGPoint(x: 5, y: 5)) == [255, 0, 0, 255])
    #expect(pixel(frame, at: CGPoint(x: 18, y: 18)) == [0, 0, 255, 255])
}

@Test func aniHonorsSequenceRatesAndEmbeddedHotspots() throws {
    let artwork = try load("timed.ani")
    #expect(artwork.width == 26)
    #expect(artwork.height == 23)
    #expect(artwork.steps.map(\.frame) == [1, 0, 1])
    #expect(artwork.steps.map(\.duration) == [0.05, 0.1, 0.15])
    #expect(artwork.hotspot == CGPoint(x: 6.0 / 26, y: 8.0 / 23))
    #expect(artwork.cursorFrames().indices == [1, 0, 0, 1, 1, 1])
}

@Test func indexedWindowsBitmapRespectsTransparencyMask() throws {
    let artwork = try load("dib8.ani")
    let frame = try #require(artwork.frames.first)
    #expect(artwork.hotspot == CGPoint(x: 4.0 / 24, y: 5.0 / 20))
    #expect(pixel(frame, at: CGPoint(x: 6, y: 8)) == [0, 255, 0, 255])
    #expect(pixel(frame, at: CGPoint(x: 1, y: 1)) == [0, 0, 0, 0])
}

@Test func aniAcceptsLegacyFullFileLength() throws {
    var data = try Data(contentsOf: fixture("timed.ani"))
    var length = UInt32(data.count).littleEndian
    withUnsafeBytes(of: &length) { data.replaceSubrange(4..<8, with: $0) }

    let artwork = try ArtworkDecoder.decode(data, filename: "legacy.ani")
    #expect(artwork.steps.map(\.frame) == [1, 0, 1])
    #expect(artwork.hotspot == CGPoint(x: 6.0 / 26, y: 8.0 / 23))
}

@Test(arguments: [5, 8]) func truncatedANIIsRejected(bytesMissing: Int) throws {
    let original = try Data(contentsOf: fixture("timed.ani"))
    let truncated = original.dropLast(bytesMissing)
    #expect(throws: ArtworkError.invalidANI) {
        _ = try ArtworkDecoder.decode(truncated, filename: "broken.ani")
    }
}

@Test func cursorUsesOneVerticalImagePerScale() throws {
    let artwork = try load("optimized.gif")
    let cursor = try RenderedCursor(artwork, size: 16)
    #expect(cursor.size == CGSize(width: 16, height: 12))
    #expect(cursor.frameCount == 5)
    #expect(cursor.representations.map { $0.sheet.width } == [16, 32])
    #expect(cursor.representations.map { $0.sheet.height } == [60, 120])

    let retina = cursor.representations[1]
    let first = cursor.frameIndex(at: 0.05)
    let second = cursor.frameIndex(at: 0.14)
    let testPoint = CGPoint(x: 18, y: 18)
    #expect(pixel(retina.frames[first], at: testPoint) == [255, 255, 255, 255])
    #expect(pixel(retina.frames[second], at: testPoint) == [0, 0, 255, 255])
    #expect(pixel(retina.sheet, at: CGPoint(x: 18, y: 18 + second * 24)) == [0, 0, 255, 255])
}

@MainActor
@Test func cursorTypesKeepIndependentDesigns() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PointerStore(storageDirectory: directory)

    await store.open(fixture("timed.ani"), for: .arrow)
    store.size = 48
    store.role = .crosshair
    await store.open(fixture("cursor.gif"), for: .crosshair)
    #expect(store.filename == "cursor.gif")
    #expect(store.hotspot == CGPoint(x: 0.5, y: 0.5))
    #expect(store.size == 32)

    store.role = .arrow
    #expect(store.filename == "timed.ani")
    #expect(store.size == 48)
    #expect(store.hotspot == CGPoint(x: 6.0 / 26, y: 8.0 / 23))

    let reopened = PointerStore(storageDirectory: directory)
    await reopened.loadSavedDesign(for: .arrow)
    #expect(reopened.filename == "timed.ani")
    reopened.role = .crosshair
    await reopened.loadSavedDesign(for: .crosshair)
    #expect(reopened.filename == "cursor.gif")
    #expect(reopened.hotspot == CGPoint(x: 0.5, y: 0.5))
}

private func fixture(_ name: String) -> URL {
    Bundle.module.resourceURL!.appending(path: "Fixtures").appending(path: name)
}

private func load(_ name: String) throws -> CursorArtwork {
    try ArtworkDecoder.load(fixture(name)).1
}

private func pixel(_ image: CGImage, at point: CGPoint) -> [UInt8] {
    let rect = CGRect(origin: point, size: CGSize(width: 1, height: 1))
    let context = CursorArtwork.context(width: 1, height: 1)!
    context.draw(image.cropping(to: rect)!, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 4))
}
