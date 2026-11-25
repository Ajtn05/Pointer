import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class PointerStore {
    private struct Selection: Codable, Equatable {
        var size = 32
        var hotspot: CGPoint
    }

    private struct SavedDesign: Codable {
        let filename: String
        let file: Data
        var selection: Selection
    }

    private struct Draft {
        var design: SavedDesign
        let artwork: CursorArtwork
        let initialHotspot: CGPoint
        var rendered: RenderedCursor
    }

    var role: CursorRole = .arrow
    var errorMessage: String?
    private(set) var activeRoles: Set<CursorRole> = []

    private var drafts: [CursorRole: Draft] = [:]
    private var loadingRoles: Set<CursorRole> = []
    private var unsavedRoles: Set<CursorRole> = []
    private var appliedSelections: [CursorRole: Selection] = [:]
    private let cursor = SystemCursor()
    private let storageDirectory: URL

    init(storageDirectory: URL = URL.applicationSupportDirectory.appending(path: "Pointer", directoryHint: .isDirectory)) {
        self.storageDirectory = storageDirectory
    }

    var artwork: CursorArtwork? { drafts[role]?.artwork }
    var rendered: RenderedCursor? { drafts[role]?.rendered }
    var filename: String? { drafts[role]?.design.filename }
    var isLoading: Bool { loadingRoles.contains(role) }
    var isActive: Bool { activeRoles.contains(role) }
    var canApply: Bool {
        guard !isLoading, let draft = drafts[role] else { return false }
        return draft.design.selection != appliedSelections[role]
    }
    var saveMessage: String? {
        unsavedRoles.contains(role) ? "This design could not be saved. Apply it again to retry." : nil
    }
    var hotspot: CGPoint { drafts[role]?.design.selection.hotspot ?? .zero }
    var canResetHotspot: Bool { drafts[role].map { $0.design.selection.hotspot != $0.initialHotspot } ?? false }

    var size: Int {
        get { drafts[role]?.design.selection.size ?? 32 }
        set {
            let clamped = min(64, max(16, newValue))
            guard var draft = drafts[role], draft.design.selection.size != clamped else { return }
            do {
                draft.rendered = try RenderedCursor(draft.artwork, size: clamped)
                draft.design.selection.size = clamped
                drafts[role] = draft
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadSavedDesign(for role: CursorRole) async {
        guard drafts[role] == nil, !loadingRoles.contains(role) else { return }
        let url = designURL(for: role)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        loadingRoles.insert(role)
        defer { loadingRoles.remove(role) }
        do {
            let (design, artwork) = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url)
                let design = try PropertyListDecoder().decode(SavedDesign.self, from: data)
                let artwork = try ArtworkDecoder.decode(design.file, filename: design.filename)
                return (design, artwork)
            }.value
            try setDesign(design, artwork: artwork, for: role)
        } catch {
            if self.role == role {
                errorMessage = "Pointer could not reopen the saved \(role.title) design. Choose the cursor file again."
            }
        }
    }

    func chooseFile() {
        let selectedRole = role
        guard !isLoading else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Cursor for \(selectedRole.title)"
        panel.prompt = "Open"
        panel.allowedContentTypes = [.gif, UTType(filenameExtension: "ani") ?? .data]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await self.open(url, for: selectedRole) }
        }
    }

    func open(_ url: URL, for role: CursorRole) async {
        guard !loadingRoles.contains(role) else { return }
        loadingRoles.insert(role)
        defer { loadingRoles.remove(role) }
        do {
            let (file, artwork) = try await Task.detached(priority: .userInitiated) {
                try ArtworkDecoder.load(url)
            }.value
            let size = drafts[role]?.design.selection.size ?? 32
            let initialHotspot = defaultHotspot(for: role, filename: url.lastPathComponent, artwork: artwork)
            let design = SavedDesign(filename: url.lastPathComponent, file: file,
                                     selection: Selection(size: size, hotspot: initialHotspot))
            try setDesign(design, artwork: artwork, for: role)
            appliedSelections.removeValue(forKey: role)
            save(role)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setHotspot(_ point: CGPoint) {
        guard var draft = drafts[role] else { return }
        draft.design.selection.hotspot = clampedHotspot(point, fallback: draft.initialHotspot)
        drafts[role] = draft
    }

    func resetHotspot() {
        if let point = drafts[role]?.initialHotspot { setHotspot(point) }
    }

    func apply() {
        guard canApply, let draft = drafts[role] else { return }
        defer { activeRoles = cursor.activeRoles }
        do {
            try cursor.apply(draft.rendered, hotspot: draft.design.selection.hotspot, to: role)
            save(role)
            if !unsavedRoles.contains(role) {
                appliedSelections[role] = draft.design.selection
            }
        } catch {
            appliedSelections.removeValue(forKey: role)
            errorMessage = error.localizedDescription
        }
    }

    func restore() {
        defer { activeRoles = cursor.activeRoles }
        do {
            try cursor.restore(role)
            appliedSelections.removeValue(forKey: role)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreAll() {
        do {
            try cursor.restoreAll()
        } catch {
            errorMessage = error.localizedDescription
        }
        activeRoles = cursor.activeRoles
        appliedSelections = appliedSelections.filter { activeRoles.contains($0.key) }
    }

    private func setDesign(_ value: SavedDesign, artwork: CursorArtwork, for role: CursorRole) throws {
        var design = value
        design.selection.size = min(64, max(16, value.selection.size))
        let initialHotspot = defaultHotspot(for: role, filename: value.filename, artwork: artwork)
        design.selection.hotspot = clampedHotspot(design.selection.hotspot, fallback: initialHotspot)
        let rendered = try RenderedCursor(artwork, size: design.selection.size)
        drafts[role] = Draft(design: design, artwork: artwork, initialHotspot: initialHotspot, rendered: rendered)
    }

    private func defaultHotspot(for role: CursorRole, filename: String, artwork: CursorArtwork) -> CGPoint {
        (filename as NSString).pathExtension.lowercased() == "ani" ? artwork.hotspot : role.defaultHotspot
    }

    private func clampedHotspot(_ point: CGPoint, fallback: CGPoint) -> CGPoint {
        guard point.x.isFinite, point.y.isFinite else { return fallback }
        return CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
    }

    private func designURL(for role: CursorRole) -> URL {
        // Retain the original app's on-disk format for the Arrow slot.
        let filename = role == .arrow ? "Design.plist" : "\(role.id).plist"
        return storageDirectory.appending(path: filename, directoryHint: .notDirectory)
    }

    private func save(_ role: CursorRole) {
        guard let design = drafts[role]?.design else { return }
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            try encoder.encode(design).write(to: designURL(for: role), options: .atomic)
            unsavedRoles.remove(role)
        } catch {
            unsavedRoles.insert(role)
        }
    }
}
