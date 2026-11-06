import AppKit
import HinterCore

// Top-level code isn't main-actor isolated in Swift 5 mode; we are on the main thread here.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let controller = AppController()
    controller.makePanel()
    let menuBar = MenuBar(app: controller)
    // Don't leave the whisper server (~600 MB RAM) running after quit.
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
        controller.whisper.stop()
    }
    // pkill/kill send SIGTERM, which skips willTerminate: route it through a normal quit so whisper-server isn't orphaned.
    signal(SIGTERM, SIG_IGN)
    let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigterm.setEventHandler { NSApp.terminate(nil) }
    sigterm.resume()

    // ⌃⌥ + key (Carbon virtual key codes). Not ⌃⌥Space: macOS uses it to switch input source.
    let keys: [(Int, String, () -> Void)] = [
        (0, "A", { controller.answer(.question) }),
        (1, "S", { controller.answer(.liveCode) }),
        (35, "P", { controller.cycleProvider() }),
        (37, "L", { controller.toggleLanguage() }),
        (4, "H", { controller.togglePanel() }),
        (8, "C", { controller.toggleClickThrough() }),
        (126, "↑", { controller.scroll(by: -220) }),
        (125, "↓", { controller.scroll(by: 220) }),
    ]
    let failed = keys.filter { !Hotkeys.register(keyCode: $0.0, $0.2) }.map { "⌃⌥\($0.1)" }
    if !failed.isEmpty { controller.hotkeyProblems = ["Горячие клавиши заняты другим приложением: \(failed.joined(separator: ", "))."] }
    Task { await controller.preflight() } // surface permission prompts at launch, warm up Whisper
    withExtendedLifetime((menuBar, sigterm)) { app.run() } // status item lives as long as the app
}
