import AppKit
import ScreenCaptureKit

/// The display under the cursor without our panel (so our own hints never get read back), ≤2000 px wide.
func captureScreen(excluding panel: NSWindow) async throws -> CGImage {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let mouse = NSEvent.mouseLocation
    let screenID = NSScreen.screens.first { $0.frame.contains(mouse) }?
        .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    guard let display = content.displays.first(where: { $0.displayID == screenID }) ?? content.displays.first
    else { throw CocoaError(.featureUnsupported) }
    let own = content.windows.filter { $0.windowID == CGWindowID(panel.windowNumber) }
    let filter = SCContentFilter(display: display, excludingWindows: own)
    let cfg = SCStreamConfiguration()
    // Cap width: full Retina images are too heavy to upload; 2000px keeps code legible.
    let w = min(filter.contentRect.width * CGFloat(filter.pointPixelScale), 2000)
    cfg.width = Int(w)
    cfg.height = Int(w * filter.contentRect.height / filter.contentRect.width)
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
}

/// JPEG file of the screen for vision models. Caller deletes the file after use.
func grabScreen(excluding panel: NSWindow) async throws -> URL {
    let image = try await captureScreen(excluding: panel)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hh-\(UUID().uuidString).jpg")
    guard let jpg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { throw CocoaError(.fileWriteUnknown) }
    try jpg.write(to: url)
    return url
}
