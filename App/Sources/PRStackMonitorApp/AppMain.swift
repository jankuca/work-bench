import AppKit

/// The process entry point.
///
/// An explicit `@main` type rather than top-level code in `main.swift`, because everything
/// this touches is `@MainActor` — ``AppDelegate``, and ``StatusItemController`` behind it.
/// Top-level code is a nonisolated synchronous context, so building the delegate there is a
/// call into the main actor from outside it, which the concurrency checker rejects. A
/// `static func main()` can be annotated, so the isolation the AppKit objects already
/// require is stated once, here, instead of being worked around at each call.
@main
enum AppMain {
    @MainActor
    static func main() {
        // The status item is the entire UI, so the app never appears in the Dock or the
        // ⌘-Tab switcher. `LSUIElement` in Info.plist covers the bundled app; setting the
        // activation policy here covers `swift run` during development, where there is no
        // bundle to read the plist from.
        let application = NSApplication.shared
        let delegate = AppDelegate()

        // `NSApplication.delegate` is a weak reference. As top-level code this was a global
        // and stayed alive for free; as a local it needs `withExtendedLifetime`, or the
        // delegate is free to be released before `run()` ever calls it.
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
