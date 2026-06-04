import AppKit
import SwiftUI

// MARK: - Main window controller
//
// Hosts the unified AppShellView. Hybrid presence: HermesLaunch launches as a
// menu-bar accessory (no Dock icon); opening this window promotes the app to a
// regular Dock app, and closing it (when no other standard windows remain)
// demotes it back to an accessory.

final class MainWindowController: NSObject {
    let model: ShellModel
    private var window: NSWindow?

    init(services: HermesServices) {
        self.model = ShellModel(services: services)
        super.init()
    }

    /// Open the window (creating it on first use) and optionally select a pane.
    /// Promotes the app to a regular Dock app; demotion back to an accessory is
    /// handled centrally by the AppDelegate's window-close observer.
    func show(section: ShellSection? = nil) {
        if window == nil { build() }
        if let section { model.selection = section }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "HermesLaunch"
        win.minSize = NSSize(width: 1040, height: 640)   // sidebar (208) + Kanban pane min (820) + slack
        win.isReleasedWhenClosed = false
        win.setFrameAutosaveName("HermesLaunchMainWindow")
        win.contentView = NSHostingView(rootView: AppShellView(model: model))
        if win.frame.origin == .zero { win.center() }
        window = win
    }
}
