import Cocoa

// Entry point. Kept in main.swift so top-level code is permitted in a
// multi-file Swift build (HermesLaunch.swift + QuickChat.swift).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
