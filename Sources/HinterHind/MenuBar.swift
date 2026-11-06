import AppKit
import UniformTypeIdentifiers
import HinterCore

/// Status-bar menu; each item calls straight into AppController.
@MainActor
final class MenuBar: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let app: AppController

    init(app: AppController) {
        self.app = app
        super.init()
        item.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Hinter Hind")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(menu, app.isLive ? "Остановить звонок" : "Начать звонок") { [app] in Task { app.isLive ? await app.stopCall() : await app.startCall() } }
        add(menu, "Проверить готовность") { [app] in Task { await app.preflight() } }
        menu.addItem(.separator())
        for k in ProviderKind.allCases {
            add(menu, "Провайдер: \(makeProvider(k).name)", on: app.provider == k) { [app] in app.provider = k }
        }
        for (id, name) in [("ru_RU", "Русский"), ("en_US", "English")] {
            add(menu, "Язык: \(name)", on: app.locale.identifier == id) { [app] in app.locale = Locale(identifier: id) }
        }
        let op = NSMenuItem(title: "Прозрачность", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for v in [0.5, 0.65, 0.85, 1.0] {
            add(sub, "\(Int(v * 100))%", on: abs(app.panel.opacity - v) < 0.01) { [app] in app.panel.opacity = v }
        }
        op.submenu = sub
        menu.addItem(op)
        let fs = NSMenuItem(title: "Размер шрифта", action: nil, keyEquivalent: "")
        let fsub = NSMenu()
        for size in [12.0, 14, 16, 18, 20, 24] {
            add(fsub, "\(Int(size))", on: app.model.fontSize == size) { [app] in app.model.fontSize = size }
        }
        fs.submenu = fsub
        menu.addItem(fs)
        menu.addItem(.separator())
        add(menu, "Резюме для этого звонка…" + (app.resumeOverride.map { " (\($0.lastPathComponent))" } ?? "")) { [app] in
            self.open([.pdf, .plainText, .init(filenameExtension: "md")!]) { app.resumeOverride = $0 }
        }
        add(menu, "Вакансия для этого звонка…" + (app.jobOverride.map { " (\($0.lastPathComponent))" } ?? "")) { [app] in
            self.open([.pdf, .plainText, .init(filenameExtension: "md")!]) { app.jobOverride = $0 }
        }
        add(menu, "Резюме по умолчанию…") { [app] in
            self.open([.pdf, .plainText, .init(filenameExtension: "md")!]) { u in self.run { try app.contextStore.setDefault(resume: u, job: nil) } }
        }
        add(menu, "Вакансия по умолчанию…") { [app] in
            self.open([.pdf, .plainText, .init(filenameExtension: "md")!]) { u in self.run { try app.contextStore.setDefault(resume: nil, job: u) } }
        }
        menu.addItem(.separator())
        add(menu, "Импорт ключа NIM из файла…") { [app] in self.open([.rtf, .plainText]) { app.importNIMKey(from: $0) } }
        add(menu, "Экспорт расшифровки…") { [app] in
            self.open([.init(filenameExtension: "hh")!], dir: app.root.appendingPathComponent("sessions")) { src in
                let save = NSSavePanel()
                save.nameFieldStringValue = src.deletingPathExtension().lastPathComponent + ".txt"
                if save.runModal() == .OK, let out = save.url { app.exportSession(src, to: out) }
            }
        }
        menu.addItem(.separator())
        add(menu, "Выход") { NSApp.terminate(nil) }
    }

    private func open(_ types: [UTType], dir: URL? = nil, _ done: @escaping (URL) -> Void) {
        NSApp.activate()
        let p = NSOpenPanel()
        p.allowedContentTypes = types
        p.directoryURL = dir
        if p.runModal() == .OK, let u = p.url { done(u) }
    }

    private func run(_ f: () throws -> Void) {
        do { try f() } catch { app.model.error = "Ошибка: \(error.localizedDescription)" }
    }

    private func add(_ menu: NSMenu, _ title: String, on: Bool = false, _ action: @escaping () -> Void) {
        let mi = NSMenuItem(title: title, action: #selector(Action.fire), keyEquivalent: "")
        let a = Action(action)
        mi.target = a
        mi.representedObject = a // retain
        mi.state = on ? .on : .off
        menu.addItem(mi)
    }
}

@MainActor
private final class Action: NSObject {
    let f: () -> Void
    init(_ f: @escaping () -> Void) { self.f = f }
    @objc func fire() { f() }
}
