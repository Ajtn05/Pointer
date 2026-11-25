import CoreGraphics

enum CursorRole: String, CaseIterable, Identifiable {
    enum Target {
        case graphics(String)
        case core(Int32)

        var name: String {
            switch self {
            case .graphics(let name): "com.apple.coregraphics." + name
            case .core(let index): "com.apple.cursor.\(index)"
            }
        }
    }

    case arrow, text, verticalText, pointingHand, openHand, closedHand, crosshair
    case resizeHorizontal, resizeVertical, resizeAscending, resizeDescending
    case move, dragCopy, dragLink, notAllowed, busy, help, zoomIn, zoomOut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arrow: "Arrow"
        case .text: "Text"
        case .verticalText: "Vertical Text"
        case .pointingHand: "Pointing Hand"
        case .openHand: "Open Hand"
        case .closedHand: "Closed Hand"
        case .crosshair: "Crosshair"
        case .resizeHorizontal: "Resize ↔"
        case .resizeVertical: "Resize ↕"
        case .resizeAscending: "Resize ↗↙"
        case .resizeDescending: "Resize ↖↘"
        case .move: "Move"
        case .dragCopy: "Drag Copy"
        case .dragLink: "Drag Link"
        case .notAllowed: "Not Allowed"
        case .busy: "Busy Arrow"
        case .help: "Help"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        }
    }

    var targets: [Target] {
        switch self {
        case .arrow: [.graphics("Arrow"), .graphics("ArrowS")]
        case .text: [.graphics("IBeam"), .graphics("IBeamS"), .graphics("IBeamXOR")]
        case .verticalText: [.core(26)]
        case .pointingHand: [.core(13)]
        case .openHand: [.core(12)]
        case .closedHand: [.core(11)]
        case .crosshair: [.core(7), .core(8), .core(20)]
        case .resizeHorizontal: [17, 18, 19, 27, 28, 38].map(Target.core)
        case .resizeVertical: [21, 22, 23, 31, 32, 36].map(Target.core)
        case .resizeAscending: [29, 30, 37].map(Target.core)
        case .resizeDescending: [33, 34, 35].map(Target.core)
        case .move: [.graphics("Move"), .core(39)]
        case .dragCopy: [.graphics("Copy"), .core(5)]
        case .dragLink: [.graphics("Alias"), .core(2)]
        case .notAllowed: [.core(3)]
        case .busy: [.core(4)]
        case .help: [.core(40)]
        case .zoomIn: [.core(42)]
        case .zoomOut: [.core(43)]
        }
    }

    var defaultHotspot: CGPoint {
        switch self {
        case .text, .verticalText, .openHand, .closedHand, .crosshair,
             .resizeHorizontal, .resizeVertical, .resizeAscending, .resizeDescending, .move,
             .notAllowed, .zoomIn, .zoomOut:
            CGPoint(x: 0.5, y: 0.5)
        default:
            .zero
        }
    }
}
