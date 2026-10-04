import AppKit

/// Switches the app between a regular Dock app and a menu-bar-only accessory (Settings → General
/// → "Show in Dock"). While hidden from the Dock, opening a window (the main window or Settings)
/// restores the regular policy so the window gets the menu bar and its keyboard shortcuts;
/// closing the last window hides the Dock icon again. The menu bar item is always there.
@MainActor
final class DockVisibility {
    static let shared = DockVisibility()

    private var showInDock = true
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.windowBecameKey(window) }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.windowWillClose(window) }
        })
    }

    func apply(showInDock: Bool) {
        self.showInDock = showInDock
        update()
    }

    /// Titled, non-panel windows: the main window and Settings. The menu bar popover is borderless.
    private static func isRegularWindow(_ window: NSWindow?) -> Bool {
        guard let window, !(window is NSPanel) else { return false }
        return window.styleMask.contains(.titled)
    }

    private func windowBecameKey(_ window: NSWindow?) {
        if Self.isRegularWindow(window) { update() }
    }

    private func windowWillClose(_ window: NSWindow?) {
        guard Self.isRegularWindow(window) else { return }
        // The closing window still counts as visible right now; look again once it has gone.
        DispatchQueue.main.async { [weak self] in self?.update(excluding: window) }
    }

    private func update(excluding closing: NSWindow? = nil) {
        let windowOpen = NSApp.windows.contains { $0 !== closing && Self.isRegularWindow($0) && $0.isVisible }
        let policy: NSApplication.ActivationPolicy = (showInDock || windowOpen) ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Coming back from accessory, the menu bar only appears once the app is activated again.
        if policy == .regular, windowOpen { NSApp.activate(ignoringOtherApps: true) }
    }
}
