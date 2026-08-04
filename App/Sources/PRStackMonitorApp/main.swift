import AppKit

// The status item is the entire UI, so the app never appears in the Dock or the
// ⌘-Tab switcher. `LSUIElement` in Info.plist covers the bundled app; setting the
// activation policy here covers `swift run` during development, where there is no
// bundle to read the plist from.
let application = NSApplication.shared
let delegate = AppDelegate()

application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
