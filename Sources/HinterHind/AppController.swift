import AppKit
import AVFoundation
import Speech
import SwiftUI
import HinterCore

/// Thread-safe slot read by the audio queue, swapped on main when the language changes.
final class TranscriberBox: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [Speaker: SpeechChannel] = [:]
    subscript(_ s: Speaker) -> SpeechChannel? {
        get { lock.withLock { map[s] } }
        set { lock.withLock { map[s] = newValue } }
    }
    func removeAll() -> [SpeechChannel] { lock.withLock { defer { map.removeAll() }; return Array(map.values) } }
}

@MainActor
final class AppController {
    let model = OverlayModel()
    private(set) var panel: OverlayPanel!
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HinterHind")
    lazy var contextStore = ContextStore(root: root)
    lazy var whisper = WhisperServer(model: root.appendingPathComponent("models/ggml-large-v3-turbo-q5_0.bin"))

    var provider: ProviderKind = .nim { didSet { updateStatus() } }
    var locale = Locale(identifier: "ru_RU") { didSet { updateStatus(); if isLive { Task { await restartTranscribers() } } } }
    var resumeOverride: URL?
    var jobOverride: URL?

    private var capture: AudioCapture?
    private let transcribers = TranscriberBox()
    private var transcript: [Utterance] = []
    private var pending: [Speaker: Int] = [:]
    private var heldCandidate: [Utterance] = [] // logged after 8 s: may still turn out to be an echo
    private var detector = TurnDetector()
    private var ticker: Timer?
    private var answerTask: Task<Void, Never>?
    private var answerGen = 0
    private var lastAnswer = ""              // last completed answer; a skipped ("—") answer restores this, never "…"
    private var lastActivity: [Speaker: Date] = [:]
    private var store: SessionStore?
    private var session: SessionID?
    var isLive: Bool { capture != nil }

    func makePanel() {
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        let host = ArrowHostingView(rootView: OverlayView(model: model))
        host.sizingOptions = [] // we size the panel ourselves from the content height
        // Autoresizing, not Auto Layout: constraints from the SwiftUI content resized the window behind our back
        // (grew it upward to 310 pt after each fit), which walked the panel off the top of the screen.
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)
        panel = OverlayPanel(content: blur)
        host.frame = blur.bounds
        keepOnScreen()
        model.onContentHeight = { [weak self] h in self?.fitPanel(to: h) }
        lastAnswer = model.answer // the hotkey help until the first real answer
        model.onNewAnswer = { [weak self] in self?.autoScroll.reset() }
        panel.onUserResize = { [weak self] f in
            guard let self else { return }
            self.maxPanelHeight = f.height
            self.fitPanel(to: self.contentHeight)
        }
        startAutoScroll()
        panel.orderFrontRegardless()
        updateStatus()
    }

    private var contentHeight: CGFloat = 0
    private var autoScroll = AutoScroll()
    private var autoScrollTimer: Timer?
    private var manualScrollUntil = Date.distantPast

    /// Grow/shrink with the text, keeping the top edge in place; scroll only past 75% of the screen.
    /// Height the user dragged the panel to: auto-height never grows past it.
    private lazy var maxPanelHeight: CGFloat = panel.frame.height

    private func fitPanel(to h: CGFloat) {
        contentHeight = h
        guard !panel.inLiveResize, let screen = panel.screen ?? NSScreen.main else { return } // don't fight the user's drag
        let vis = screen.visibleFrame
        let height = min(max(h, 120), maxPanelHeight, vis.height).rounded()
        var f = panel.frame
        guard abs(f.height - height) > 1 else { return }
        let top = min(f.maxY, vis.maxY)
        f.size.height = height
        f.origin.y = max(vis.minY, top - height)
        panel.setFrame(f, display: true)
    }

    /// Pull the panel back inside the visible screen (a saved frame from another display, or any drift).
    private func keepOnScreen() {
        guard let vis = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        var f = panel.frame
        f.size.width = min(f.width, vis.width)
        f.size.height = min(f.height, vis.height)
        f.origin.x = min(max(f.minX, vis.minX), vis.maxX - f.width)
        f.origin.y = min(max(f.minY, vis.minY), vis.maxY - f.height)
        if f != panel.frame { panel.setFrame(f, display: true) }
    }

    func scroll(by dy: CGFloat) {
        let maxY = max(0, contentHeight - panel.frame.height)
        model.scrollY = min(max(0, model.scrollY + dy), maxY)
        manualScrollUntil = Date().addingTimeInterval(10) // manual scrolling pauses auto-scroll
    }

    /// Overflowing text scrolls itself: a step every 2.5 s, pause at both ends, then back to the top.
    private func startAutoScroll() {
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date() > self.manualScrollUntil else { return }
                if let y = self.autoScroll.next(maxY: Double(max(0, self.contentHeight - self.panel.frame.height))) {
                    self.model.scrollY = CGFloat(y)
                }
            }
        }
    }

    func updateStatus() {
        let lang = locale.identifier.hasPrefix("ru") ? "RU" : "EN"
        model.status = "\(makeProvider(provider).name) · \(lang)\(isLive ? " · ● запись" : "")\(panel?.clickThrough == true ? " · сквозь" : "")"
    }

    // MARK: call lifecycle

    func startCall() async {
        guard !isLive else { return }
        model.error = nil
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            return fail("Нет доступа к микрофону: Системные настройки → Конфиденциальность → Микрофон.")
        }
        do {
            let key = try SessionStore.loadOrCreateKey()
            store = SessionStore(root: root, key: key)
            session = try store?.begin()
            try await startTranscribers()
            let cap = AudioCapture()
            cap.onError = { [weak self] e in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.fail("Захват звука остановлен: \(e.localizedDescription)")
                    Task { await self.stopCall() }
                }
            }
            let box = transcribers // audio queue touches only the locked box, never self
            try await cap.start(onSystem: { b in box[.interviewer]?.feed(b) },
                                onMic: { b in box[.candidate]?.feed(b) })
            capture = cap
            ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
            updateStatus()
            let ctx = try? contextStore.load(resumeOverride: resumeOverride, jobOverride: jobOverride)
            if model.error == nil, ctx?.resume.isEmpty != false || ctx?.job.isEmpty != false {
                model.error = "Резюме или вакансия не загружены — ответы будут общими. Меню 💬 → «…по умолчанию»."
            }
        } catch {
            await stopTranscribers()
            fail("Не удалось начать: \(error.localizedDescription). Если это права — Системные настройки → Конфиденциальность → Запись экрана и системного звука.")
        }
    }

    /// Run at launch and from the menu: every permission prompt and slow warm-up happens now, not mid-call.
    var hotkeyProblems: [String] = []

    func preflight() async {
        var problems = hotkeyProblems
        if !(await AVCaptureDevice.requestAccess(for: .audio)) {
            problems.append("Микрофон: Системные настройки → Конфиденциальность → Микрофон.")
        }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            problems.append("Запись экрана и системного звука: включите HinterHind в Системных настройках и перезапустите приложение.")
        }
        // Reading Keychain items now surfaces any "allow access" prompt before the call.
        if (try? SessionStore.loadOrCreateKey()) == nil { problems.append("Keychain: нет доступа к ключу шифрования расшифровок.") }
        if provider == .nim, (try? Keychain.get(account: "nim-api-key")) ?? nil == nil {
            problems.append("Нет ключа NIM: меню 💬 → «Импорт ключа NIM из файла…».")
        }
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        if speech != .authorized { problems.append("Распознавание речи (для вашего микрофона): Системные настройки → Конфиденциальность → Распознавание речи.") }
        do {
            try await whisper.start()
            if !isLive { whisper.stop() } // checked; loaded again at call start
        } catch {
            problems.append("Whisper недоступен (\(error)) — будет распознаватель Apple, термины хуже.")
        }
        let ctx = try? contextStore.load()
        if ctx?.resume.isEmpty != false || ctx?.job.isEmpty != false {
            problems.append("Резюме или вакансия не загружены — меню 💬 → «…по умолчанию».")
        }
        if problems.isEmpty {
            model.error = nil
            model.answer = "✓ Готово к звонку: права есть, Whisper загружен, резюме и вакансия на месте."
        } else {
            model.error = "Подготовьте до звонка:\n• " + problems.joined(separator: "\n• ")
        }
    }

    func stopCall() async {
        capture?.stop(); capture = nil
        ticker?.invalidate(); ticker = nil
        await stopTranscribers()
        whisper.stop() // frees ~700 MB between calls; restarting takes ~0.5 s
        flushHeld(olderThan: 0, now: Date())
        resumeOverride = nil; jobOverride = nil // overrides are per call
        transcript.removeAll(); pending.removeAll(); lastActivity.removeAll()
        model.heardInterviewer = ""; model.heardCandidate = ""
        updateStatus()
    }

    private func startTranscribers() async throws {
        let ctx = (try? contextStore.load(resumeOverride: resumeOverride, jobOverride: jobOverride)) ?? CandidateContext(resume: "", job: "")
        let prompt = whisperPrompt(ctx)
        var useWhisper = true
        do { try await whisper.start() } catch {
            useWhisper = false
            model.error = "Whisper недоступен (\(error)), использую распознаватель Apple — английские термины будут хуже."
        }
        // Whisper results arrive ~0.5 s after speech ends (segmentation pause), so wait less on top.
        detector = TurnDetector(silence: useWhisper ? 0.6 : 1.2) // also: no stale state from the previous call
        // Whisper (GPU) only where terms matter — the interviewer. Your mic goes to Apple's on-device recognizer (Neural Engine,
        // far cooler); it only feeds context and echo removal, and hints are triggered by the interviewer channel anyway.
        for sp in [Speaker.interviewer, .candidate] {
            let t: SpeechChannel = useWhisper && sp == .interviewer
                ? WhisperTranscriber(server: whisper, locale: locale, speaker: sp, prompt: prompt)
                : Transcriber(locale: locale, speaker: sp)
            t.onActivity = { [weak self] at in
                DispatchQueue.main.async { self?.detector.speechActivity(sp, at: at); self?.lastActivity[sp] = at }
            }
            do {
                try await t.start { [weak self] u, final in DispatchQueue.main.async { self?.ingest(u, final: final) } }
            } catch where sp == .candidate {
                model.error = "Ваш микрофон не распознаётся (\(error.localizedDescription)) — подсказки работают, но без ваших реплик."
                continue
            }
            transcribers[sp] = t // publish only after start() set format/input, so feed() never races it
        }
    }

    private func stopTranscribers() async {
        for t in transcribers.removeAll() { await t.stop() }
    }

    private func restartTranscribers() async {
        await stopTranscribers()
        do { try await startTranscribers() } catch { fail("Не удалось сменить язык: \(error.localizedDescription)") }
    }

    private func ingest(_ u: Utterance, final: Bool) {
        guard isLive else { return } // late results drained after stopCall
        if u.speaker == .candidate {
            let recent = transcript.filter { $0.speaker == .interviewer && u.at.timeIntervalSince($0.at) < 15 }
            if isEcho(u, interviewer: recent) { return } // speakers leaking into the mic
        }
        if u.speaker == .interviewer, final { dropEchoes(of: u) }
        if let i = pending[u.speaker] { transcript[i] = u } else { transcript.append(u); pending[u.speaker] = transcript.count - 1 }
        if final {
            pending[u.speaker] = nil
            if u.speaker == .interviewer { log("Интервьюер: \(u.text)", at: u.at) } else { heldCandidate.append(u) }
        }
        detector.ingest(u, isFinal: final)
        if u.speaker == .interviewer { model.heardInterviewer = u.text } else { model.heardCandidate = u.text }
    }

    /// The mic copy of an interviewer phrase often lands before the interviewer's own (longer) segment.
    private func dropEchoes(of u: Utterance) {
        let idx = transcript.indices.filter { transcript[$0].speaker == .candidate && $0 != pending[.candidate] }
        let hits = echoesOf(u, in: idx.map { transcript[$0] }).map { idx[$0] }
        guard !hits.isEmpty else { return }
        let removed = hits.map { transcript[$0] }
        for i in hits.reversed() { transcript.remove(at: i) }
        for (sp, p) in pending { pending[sp] = p - hits.filter { $0 < p }.count }
        heldCandidate.removeAll { removed.contains($0) }
    }

    private func flushHeld(olderThan age: TimeInterval, now: Date) {
        while let h = heldCandidate.first, now.timeIntervalSince(h.at) >= age {
            log("Кандидат: \(h.text)", at: h.at)
            heldCandidate.removeFirst()
        }
    }

    private func tick() {
        let now = Date()
        flushHeld(olderThan: 8, now: now)
        // Keep memory flat on long calls; prompt only uses the last window anyway.
        if pending.isEmpty, let cut = transcript.firstIndex(where: { now.timeIntervalSince($0.at) <= transcriptWindow }), cut > 0 {
            transcript.removeFirst(cut)
        }
        if let q = detector.tick(now: now) {
            log("· вопрос обнаружен: «\(q.prefix(120))»", at: now)
            answer(.question, question: q)
        }
        // Shows whether the app thinks the interviewer is talking (constant "речь" = noise keeps the turn open).
        let speaking = lastActivity[.interviewer].map { now.timeIntervalSince($0) < 0.4 } ?? false
        if speaking != model.interviewerSpeaking { model.interviewerSpeaking = speaking }
    }

    // MARK: answering

    func answer(_ mode: Mode, question: String? = nil) {
        if answerTask != nil { log("· предыдущий ответ прерван новым запуском", at: Date()) }
        answerTask?.cancel()
        model.error = nil
        answerGen += 1
        let gen = answerGen
        answerTask = Task { @MainActor in
            defer {
                if gen == self.answerGen { self.answerTask = nil }
            }
            var image: URL?
            defer { if let image { try? FileManager.default.removeItem(at: image) } }
            let source = switch (mode, question) {
            case (.question, nil): "⌃⌥A"
            case (.question, let q?): "голос: «\(q.prefix(80))»"
            case (.liveCode, _): "⌃⌥S"
            }
            do {
                if mode == .liveCode {
                    do { image = try await grabScreen(excluding: panel) } catch {
                        throw ScreenError(underlying: error)
                    }
                }
                let ctx = try contextStore.load(resumeOverride: resumeOverride, jobOverride: jobOverride)
                // Cancelled while suspended: a newer answer owns the panel now.
                guard !Task.isCancelled else { return }
                let req = buildPrompt(mode: mode, context: ctx, transcript: transcript, now: Date(), imagePath: image, question: question)
                model.answer = "…"
                var text = ""
                for try await chunk in makeProvider(provider).stream(req) {
                    if Task.isCancelled { return }
                    text += chunk
                    if !isSkipAnswer(text) { model.answer = sanitizeHint(text) }
                }
                guard !Task.isCancelled else { return } // cancelled streams end without throwing
                if isSkipAnswer(text) { // model judged it not a question/task
                    model.answer = lastAnswer
                    log("· модель пропустила (—), \(source)", at: Date())
                    return
                }
                if text.isEmpty { model.answer = lastAnswer; model.error = "Провайдер вернул пустой ответ."; log("· пустой ответ, \(source)", at: Date()); return }
                text = sanitizeHint(text)
                lastAnswer = text
                log("Подсказка (\(makeProvider(provider).name), \(source)): \(text)", at: Date())
            } catch is CancellationError {
            } catch {
                if Task.isCancelled { return }
                if model.answer == "…" { model.answer = lastAnswer }
                model.error = describe(error)
                log("· ошибка: \(describe(error)), \(source)", at: Date())
            }
        }
    }

    private func describe(_ e: Error) -> String {
        switch e {
        case ProviderError.notInstalled(let n): "\(n) не установлен. Переключите провайдера (⌃⌥P)."
        case ProviderError.missingKey: "Нет ключа NIM: меню → «Импорт ключа NIM из файла…»."
        case ProviderError.failed(let m): "Ошибка провайдера: \(m.prefix(200))"
        case let e as ScreenError: "Не удалось снять экран: \(e.underlying.localizedDescription). Проверьте Системные настройки → Конфиденциальность → Запись экрана и системного звука."
        default: "Ошибка: \(e.localizedDescription)"
        }
    }

    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    private func log(_ line: String, at: Date) {
        guard let store, let session else { return }
        do { try store.append("[\(Self.clock.string(from: at))] \(line)", to: session) } catch { model.error = "Не удалось сохранить расшифровку: \(error.localizedDescription)" }
    }

    private func fail(_ msg: String) { model.error = msg; updateStatus() }

    // MARK: controls

    func cycleProvider() {
        let all = ProviderKind.allCases
        provider = all[(all.firstIndex(of: provider)! + 1) % all.count]
    }

    func toggleLanguage() { locale = Locale(identifier: locale.identifier.hasPrefix("ru") ? "en_US" : "ru_RU") }

    func togglePanel() { panel.isVisible ? panel.orderOut(nil) : panel.orderFrontRegardless() }

    func toggleClickThrough() { panel.clickThrough.toggle(); updateStatus() }

    func importNIMKey(from url: URL) {
        do {
            let key = try extractAPIKey(fromRTF: Data(contentsOf: url))
            try Keychain.set(Data(key.utf8), account: "nim-api-key")
            model.error = nil
            model.answer = "Ключ NIM сохранён в Keychain. Исходный файл можно удалить."
        } catch { fail("Не удалось импортировать ключ: \(error)") }
    }

    func exportSession(_ file: URL, to out: URL) {
        guard let key = try? SessionStore.loadOrCreateKey() else { return fail("Нет ключа шифрования в Keychain.") }
        do { try SessionStore(root: root, key: key).export(file.deletingPathExtension().lastPathComponent, to: out) }
        catch { fail("Не удалось расшифровать: \(error.localizedDescription)") }
    }
}

struct ScreenError: Error { let underlying: Error }

/// Keeps the arrow cursor over the whole panel: any cursor change over an invisible window looks odd in a screen share.
final class ArrowHostingView<Content: View>: NSHostingView<Content> {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
}
