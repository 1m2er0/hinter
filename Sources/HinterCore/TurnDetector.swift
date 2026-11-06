import Foundation

/// Collects the interviewer's turn and returns it once, after `silence` seconds of quiet, if it reads like a question or task.
public final class TurnDetector {
    let silence: TimeInterval
    var lastSpeech: Date?
    var lastIsFinal = false
    var turn: [String] = []

    public init(silence: TimeInterval = 1.2) { self.silence = silence }

    public func ingest(_ u: Utterance, isFinal: Bool) {
        guard u.speaker == .interviewer else { return }
        lastSpeech = u.at
        lastIsFinal = isFinal
        if isFinal { turn.append(u.text) }
    }

    /// Speech heard but not yet transcribed (Whisper has no partial results): keeps the turn open.
    public func speechActivity(_ speaker: Speaker, at: Date) {
        guard speaker == .interviewer else { return }
        lastSpeech = at
        lastIsFinal = false
    }

    public func tick(now: Date) -> String? {
        guard !turn.isEmpty, lastIsFinal, let last = lastSpeech, now.timeIntervalSince(last) >= silence else { return nil }
        let text = turn.joined(separator: " ")
        turn.removeAll() // statements are dropped, not glued onto the next question
        return looksLikeQuestion(text) ? text : nil
    }
}

private let cues = [
    // ru
    "как", "что", "чем", "почему", "зачем", "когда", "где", "куда", "откуда", "какой", "какая", "какое", "какие", "каким", "какую", "каких",
    "сколько", "кто", "ли", "расскажи", "расскажите", "объясни", "объясните", "опиши", "опишите", "напиши", "напишите", "приведи",
    "приведите", "назови", "назовите", "сравни", "сравните", "реализуй", "реализуйте", "покажи", "покажите", "можете", "могли", "доводилось", "приходилось",
    // en
    "what", "why", "how", "when", "where", "which", "who", "explain", "describe", "tell", "walk", "write", "implement", "compare",
    "tell",
]
// English auxiliaries only mark a question at the start ("Is it…", not "This is…").
private let leadingCues: Set<String> = ["can", "could", "would", "do", "did", "does", "have", "has", "is", "are", "should", "will"]

/// Cheap gate before spending an LLM call; the model gets a second chance to skip via "—".
public func looksLikeQuestion(_ text: String) -> Bool {
    let list = text.lowercased().split { !$0.isLetter }.map(String.init)
    guard list.count >= 3 else { return false } // "Алло? Алло?", "Да?" — not worth a hint
    if text.contains("?") { return true }
    if let first = list.first, leadingCues.contains(first) { return true }
    let words = Set(list)
    return cues.contains { words.contains($0) }
}

private func stems(_ s: String) -> [String] {
    // 4-letter prefix absorbs inflection and re-recognition noise ("работает"/"работаешь").
    s.lowercased().split { !$0.isLetter && !$0.isNumber }.map { String($0.prefix(4)) }
}

/// Speakers leak the interviewer into the mic. Echo = mic speech at the same moment (±2s) that mostly repeats the interviewer's words;
/// an answer comes later, and talking over them uses your own words.
public func isEcho(_ mic: Utterance, interviewer recent: [Utterance]) -> Bool {
    recent.contains { abs(mic.at.timeIntervalSince($0.at)) <= 2 && repeats(mic.text, $0.text) }
}

/// Mic utterances that turned out to be copies of an interviewer phrase transcribed later
/// (the interviewer channel arrives as one long segment, after the mic's shorter ones).
public func echoesOf(_ interviewer: Utterance, in candidate: [Utterance]) -> [Int] {
    candidate.indices.filter { i in
        let dt = interviewer.at.timeIntervalSince(candidate[i].at)
        return dt >= -2 && dt <= 8 && repeats(candidate[i].text, interviewer.text)
    }
}

private func repeats(_ mic: String, _ original: String) -> Bool {
    let m = stems(mic)
    guard m.count >= 3 else { return false }
    let heard = Set(stems(original))
    return Double(m.filter(heard.contains).count) / Double(m.count) >= 0.6
}
