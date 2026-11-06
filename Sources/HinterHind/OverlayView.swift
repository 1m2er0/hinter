import SwiftUI

final class OverlayModel: ObservableObject {
    @Published var status = ""
    @Published var answer = "⌃⌥A — ответ · ⌃⌥S — задача с экрана · ⌃⌥P — провайдер · ⌃⌥L — язык · ⌃⌥H — скрыть · ⌃⌥C — сквозные клики · ⌃⌥↑↓ — прокрутка"
    @Published var error: String?
    @Published var heardInterviewer = ""
    @Published var heardCandidate = ""
    @Published var scrollY: CGFloat = 0
    @Published var interviewerSpeaking = false
    @Published var fontSize: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "fontSize")
        return v >= 10 ? v : 14
    }() { didSet { UserDefaults.standard.set(Double(fontSize), forKey: "fontSize") } }
    /// Full content height; the panel resizes to it (capped by the screen).
    var onContentHeight: ((CGFloat) -> Void)?
    var onNewAnswer: (() -> Void)?
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    // No ScrollView: the text is offset inside a clipped frame. Deterministic programmatic scrolling
    // (ScrollPosition.scrollTo didn't move it), and no scroll gestures/cursor over the panel.
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true) // full height, never squeezed by the panel
            // PreferenceKey + GeometryReader never reported the height here (stayed 0), so the panel
            // neither auto-sized nor auto-scrolled; onGeometryChange does.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in model.onContentHeight?(h) }
            .offset(y: -model.scrollY)
            .animation(.easeOut(duration: 0.3), value: model.scrollY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            .onChange(of: model.answer) { old, new in
                // A new answer (not a streamed continuation) starts from the top.
                guard !new.hasPrefix(old) || old == "…" else { return }
                model.onNewAnswer?()
                if model.scrollY != 0 { model.scrollY = 0 }
            }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(model.status).font(.caption.monospaced()).foregroundStyle(.secondary)
                if model.interviewerSpeaking { Text("· речь").font(.caption.monospaced()).foregroundStyle(.green) }
            }
            // What each channel heard, so speaker separation is visible.
            if !model.heardInterviewer.isEmpty {
                Text("Собеседник: \(model.heardInterviewer)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if !model.heardCandidate.isEmpty {
                Text("Вы: \(model.heardCandidate)").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            // No .textSelection: selectable text turns the cursor into an I-beam, visible in screen share.
            ForEach(Array(model.answer.components(separatedBy: "```").enumerated()), id: \.offset) { i, part in
                if i % 2 == 1 { // odd segments between ``` fences are code
                    Text(part.drop { $0 != "\n" }.trimmingCharacters(in: .newlines))
                        .font(.system(size: model.fontSize - 2, design: .monospaced))
                        .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                } else if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text((try? AttributedString(markdown: part, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(part))
                        .font(.system(size: model.fontSize))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let e = model.error { Text("⚠︎ \(e)").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
