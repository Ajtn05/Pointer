import CoreGraphics
import Darwin
import Foundation

@MainActor
final class SystemCursor {
    private struct Registration {
        let size: CGSize
        let hotspot: CGPoint
        let frameCount: Int
        let delay: CGFloat
        let images: CFArray
    }

    private typealias Connection = @convention(c) () -> Int32
    private typealias Register = @convention(c) (
        Int32, UnsafePointer<CChar>, Bool, Bool, CGSize, CGPoint, Int, CGFloat, CFArray, UnsafeMutablePointer<Int32>
    ) -> Int32
    private typealias CopyImages = @convention(c) (
        Int32, UnsafePointer<CChar>, UnsafeMutablePointer<CGSize>, UnsafeMutablePointer<CGPoint>,
        UnsafeMutablePointer<Int>, UnsafeMutablePointer<CGFloat>, UnsafeMutablePointer<Unmanaged<CFArray>?>
    ) -> Int32
    private typealias CopyCoreImages = @convention(c) (
        Int32, Int32, UnsafeMutablePointer<Unmanaged<CFArray>?>, UnsafeMutablePointer<CGSize>,
        UnsafeMutablePointer<CGPoint>, UnsafeMutablePointer<Int>, UnsafeMutablePointer<CGFloat>
    ) -> Int32
    private typealias Select = @convention(c) (Int32, Int32) -> Int32

    private struct SkyLight {
        let connection: Connection
        let register: Register
        let copyImages: CopyImages
        let copyCoreImages: CopyCoreImages?
        let select: Select

        init?() {
            guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
                                      RTLD_LAZY | RTLD_LOCAL) else { return nil }
            guard let connection = dlsym(handle, "CGSMainConnectionID"),
                  let register = dlsym(handle, "CGSRegisterCursorWithImages"),
                  let copy = dlsym(handle, "CGSCopyRegisteredCursorImages"),
                  let select = dlsym(handle, "CGSSetSystemDefinedCursor") else {
                dlclose(handle)
                return nil
            }
            // These function pointers are used for the life of the application.
            self.connection = unsafeBitCast(connection, to: Connection.self)
            self.register = unsafeBitCast(register, to: Register.self)
            self.copyImages = unsafeBitCast(copy, to: CopyImages.self)
            let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
            self.copyCoreImages = dlsym(defaultHandle, "CoreCursorCopyImages").map {
                unsafeBitCast($0, to: CopyCoreImages.self)
            }
            self.select = unsafeBitCast(select, to: Select.self)
        }
    }

    private lazy var api = SkyLight()
    private var originals: [CursorRole: [String: Registration]] = [:]

    var activeRoles: Set<CursorRole> { Set(originals.keys) }

    func apply(_ rendered: RenderedCursor, hotspot: CGPoint, to role: CursorRole) throws {
        guard let api else { throw CursorError.unavailable(role) }
        let cid = api.connection()
        guard cid != 0 else { throw CursorError.unavailable(role) }

        let registration = Registration(size: rendered.size, hotspot: rendered.hotspot(at: hotspot),
                                        frameCount: rendered.frameCount, delay: rendered.delay,
                                        images: rendered.representations.map(\.sheet) as CFArray)
        if originals[role] == nil {
            var snapshots: [String: Registration] = [:]
            for target in role.targets {
                snapshots[target.name] = snapshot(target, connection: cid, api: api)
            }
            guard !snapshots.isEmpty else { throw CursorError.unavailable(role) }
            originals[role] = snapshots
        }

        for target in role.targets where originals[role]?[target.name] != nil {
            let result = register(registration, as: target.name, connection: cid, api: api)
            if result != 0 {
                try restore(role)
                throw CursorError.registration(role, result)
            }
        }
        if role == .arrow { _ = api.select(cid, 0) }
    }

    func restore(_ role: CursorRole) throws {
        guard let snapshots = originals[role], let api else { return }
        let cid = api.connection()
        var failure: Int32?
        for (name, original) in snapshots {
            let result = register(original, as: name, connection: cid, api: api)
            if result != 0 { failure = result }
        }
        if role == .arrow { _ = api.select(cid, 0) }
        if let failure { throw CursorError.restoration(role, failure) }
        originals.removeValue(forKey: role)
    }

    func restoreAll() throws {
        var firstError: Error?
        for role in CursorRole.allCases {
            do {
                try restore(role)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    private func snapshot(_ target: CursorRole.Target, connection: Int32, api: SkyLight) -> Registration? {
        var size = CGSize.zero
        var hotspot = CGPoint.zero
        var frameCount = 0
        var delay: CGFloat = 0
        var images: Unmanaged<CFArray>?
        let result = target.name.withCString {
            api.copyImages(connection, $0, &size, &hotspot, &frameCount, &delay, &images)
        }
        let registered = images?.takeRetainedValue()
        if result == 0, let registered, (1...24).contains(frameCount) {
            return Registration(size: size, hotspot: hotspot, frameCount: frameCount, delay: delay,
                                images: registered)
        }

        // Some numbered system cursors have no named registration until first use.
        guard result != 0, case .core(let index) = target, let copyCore = api.copyCoreImages else { return nil }
        images = nil
        let coreResult = copyCore(connection, index, &images, &size, &hotspot, &frameCount, &delay)
        let system = images?.takeRetainedValue()
        guard coreResult == 0, let system, (1...24).contains(frameCount) else { return nil }
        return Registration(size: size, hotspot: hotspot, frameCount: frameCount, delay: delay, images: system)
    }

    private func register(_ cursor: Registration, as name: String, connection: Int32, api: SkyLight) -> Int32 {
        var seed: Int32 = 0
        return name.withCString {
            api.register(connection, $0, true, false, cursor.size, cursor.hotspot,
                         cursor.frameCount, cursor.delay, cursor.images, &seed)
        }
    }
}

enum CursorError: LocalizedError {
    case unavailable(CursorRole), rendering, registration(CursorRole, Int32), restoration(CursorRole, Int32)

    var errorDescription: String? {
        switch self {
        case .unavailable(let role): "Pointer could not access the \(role.title) cursor on this version of macOS."
        case .rendering: "Pointer could not render this cursor."
        case .registration(let role, let code): "macOS rejected the \(role.title) cursor (\(code))."
        case .restoration(let role, let code): "macOS could not restore the \(role.title) cursor (\(code)). Try again."
        }
    }
}
