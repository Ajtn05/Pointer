import SwiftUI

@main
struct PointerApp: App {
    static let windowID = "pointer"
    @NSApplicationDelegateAdaptor(PointerDelegate.self) private var delegate

    var body: some Scene {
        Window("Pointer", id: Self.windowID) {
            PointerView(store: delegate.store)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Cursor…", action: delegate.store.chooseFile)
                    .keyboardShortcut("o")
                    .disabled(delegate.store.isLoading)
            }
        }

        MenuBarExtra("Pointer", systemImage: "cursorarrow") {
            PointerMenu(store: delegate.store)
        }
    }
}

private struct PointerMenu: View {
    let store: PointerStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Pointer", action: showWindow)
        BackgroundButton()
        Divider()
        Button("Restore All Defaults") {
            store.restoreAll()
            if store.errorMessage != nil { showWindow() }
        }
        .disabled(store.activeRoles.isEmpty)
        Divider()
        Button("Quit Pointer") { NSApp.terminate(nil) }
    }

    private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: PointerApp.windowID)
        NSApp.activate()
    }
}

struct BackgroundButton: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Button("Run in Background") {
            dismissWindow(id: PointerApp.windowID)
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

@MainActor
final class PointerDelegate: NSObject, NSApplicationDelegate {
    let store = PointerStore()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.restoreAll()
    }
}
