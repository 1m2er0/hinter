import AppKit

/// Floating panel excluded from screen capture/sharing.
final class OverlayPanel: NSPanel, NSWindowDelegate {
    /// Called when the user finishes resizing with the mouse.
    var onUserResize: ((NSRect) -> Void)?
    var opacity: CGFloat = 0.85 { didSet { alphaValue = opacity } }
    var clickThrough = false { didSet { ignoresMouseEvents = clickThrough } }

    init(content: NSView) {
        // Last size the user chose (width, and height as the cap for auto-height).
        let saved = NSRectFromString(UserDefaults.standard.string(forKey: "panelFrame") ?? "")
        super.init(contentRect: saved.width >= 300 ? saved : NSRect(x: 80, y: 400, width: 560, height: 500),
                   styleMask: [.nonactivatingPanel, .borderless, .resizable], // resize cursor appears only right at the edges
                   backing: .buffered, defer: false)
        minSize = NSSize(width: 320, height: 120)
        delegate = self
        sharingType = .none
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        alphaValue = opacity
        contentView = content
    }

    override var canBecomeKey: Bool { true }

    func windowDidEndLiveResize(_ notification: Notification) {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: "panelFrame")
        onUserResize?(frame)
    }

    func windowDidMove(_ notification: Notification) {
        guard !inLiveResize else { return }
        var f = NSRectFromString(UserDefaults.standard.string(forKey: "panelFrame") ?? "")
        guard f.width >= 300 else { return }
        f.origin = NSPoint(x: frame.minX, y: frame.maxY - f.height) // remember position, keep the user's height cap
        UserDefaults.standard.set(NSStringFromRect(f), forKey: "panelFrame")
    }
}
