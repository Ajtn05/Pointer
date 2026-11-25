import SwiftUI

struct PointerView: View {
    @Bindable var store: PointerStore
    @State private var isDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 9) {
                Picker("Cursor type", selection: $store.role) {
                    ForEach(CursorRole.allCases) { role in
                        Text(role.title)
                            .tag(role)
                    }
                }
                .frame(width: 228)
                Spacer()
                Circle()
                    .fill(store.isActive ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(store.isActive ? "Custom active" : "Default active")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            preview
                .frame(height: 192)
                .clipShape(.rect(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isDropTarget ? Color.accentColor : Color.primary.opacity(0.12),
                                      lineWidth: isDropTarget ? 2 : 1)
                        .allowsHitTesting(false)
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard urls.count == 1, let url = urls.first, url.isFileURL, !store.isLoading else { return false }
                    let role = store.role
                    Task { await store.open(url, for: role) }
                    return true
                } isTargeted: { isDropTarget = $0 }

            HStack(spacing: 12) {
                Image(systemName: store.filename == nil ? "document" : "document.fill")
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.filename ?? "No cursor selected")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let artwork = store.artwork {
                        Text("\(artwork.width) × \(artwork.height) px · \(artwork.steps.count) \(artwork.steps.count == 1 ? "frame" : "frames")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("GIF or Windows ANI")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Open File…", action: store.chooseFile)
                    .disabled(store.isLoading)
            }

            Divider()

            HStack(spacing: 12) {
                Text("Size")
                    .font(.callout)
                Slider(value: Binding(get: { Double(store.size) }, set: { store.size = Int($0) }),
                       in: 16...64, step: 1) {
                    Text("Pointer size")
                }
                .labelsHidden()
                Text("\(store.size) pt")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            .disabled(store.artwork == nil)

            HStack(spacing: 10) {
                Button("Restore Default", action: store.restore)
                    .disabled(!store.isActive)
                Spacer()
                Button("Reset Click Point", action: store.resetHotspot)
                    .disabled(!store.canResetHotspot)
                Button("Apply", action: store.apply)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!store.canApply)
            }
            if let message = store.saveMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 466)
        .task(id: store.role) { await store.loadSavedDesign(for: store.role) }
        .toolbar {
            ToolbarItem {
                BackgroundButton()
            }
        }
        .alert("Pointer", isPresented: Binding(get: { store.errorMessage != nil },
                                               set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var preview: some View {
        ZStack(alignment: .bottom) {
            Canvas { context, size in
                let tile = 16.0
                let color = Color.primary.opacity(0.035)
                for row in 0..<Int(ceil(size.height / tile)) {
                    for column in stride(from: row % 2, to: Int(ceil(size.width / tile)), by: 2) {
                        let square = CGRect(x: Double(column) * tile, y: Double(row) * tile, width: tile, height: tile)
                        context.fill(Path(square), with: .color(color))
                    }
                }
            }
            .background(.background)
            .accessibilityHidden(true)

            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading cursor")
            } else if let rendered = store.rendered {
                VStack(spacing: 10) {
                    AnimatedPreview(cursor: rendered, hotspot: store.hotspot, setHotspot: store.setHotspot)
                        .frame(width: 140, height: 128)
                        .id(store.role)
                    Text("Enlarged preview · Click to set the click point")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "cursorarrow.rays")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Drop a cursor file")
                        .font(.callout.weight(.medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct AnimatedPreview: View {
    let cursor: RenderedCursor
    let hotspot: CGPoint
    let setHotspot: (CGPoint) -> Void
    @State private var start = Date.now
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / cursor.size.width,
                            geometry.size.height / cursor.size.height)
            let width = cursor.size.width * scale
            let height = cursor.size.height * scale
            let frames = cursor.representations[displayScale >= 1.5 ? 1 : 0].frames
            let clickPoint = cursor.hotspot(at: hotspot)

            TimelineView(.animation(paused: reduceMotion || cursor.frameCount == 1)) { timeline in
                let seconds = max(0, timeline.date.timeIntervalSince(start))
                let frame = reduceMotion ? 0 : cursor.frameIndex(at: seconds)
                ZStack(alignment: .topLeading) {
                    Image(decorative: frames[frame], scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: width, height: height)
                    Image(systemName: "plus.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(Color.accentColor, in: .circle)
                        .position(x: clickPoint.x * scale, y: clickPoint.y * scale)
                        .allowsHitTesting(false)
                }
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { event in
                    setHotspot(CGPoint(x: event.location.x / width, y: event.location.y / height))
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cursor preview")
        .accessibilityValue("Click point at \(Int(hotspot.x * 100)) percent across and \(Int(hotspot.y * 100)) percent down")
    }
}
