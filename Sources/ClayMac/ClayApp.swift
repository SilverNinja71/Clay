import SwiftUI
import ClayKit
#if os(macOS)
import AppKit
#endif

/// Universal app entry. The same file works as the iPad app's entry point (see README).
@main
struct ClayApp: App {
    init() {
        #if os(macOS)
        // When launched straight from `swift run` (no .app bundle), become a regular app with a Dock icon.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
        #endif
    }

    var body: some Scene {
        WindowGroup("Clay") {
            ClayRootView()
                #if os(macOS)
                .frame(minWidth: 1100, minHeight: 720)
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1380, height: 880)
        .commands {
            // Undo/redo/delete are handled by the workspace keymap.
            CommandGroup(replacing: .undoRedo) {}
        }
        #endif
    }
}
