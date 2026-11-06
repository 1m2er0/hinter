import Foundation

public enum Mode: Sendable { case question, liveCode }
public enum Speaker: Sendable { case interviewer, candidate }

public struct Utterance: Sendable, Equatable {
    public let speaker: Speaker
    public let text: String
    public let at: Date
    public init(speaker: Speaker, text: String, at: Date) { self.speaker = speaker; self.text = text; self.at = at }
}

public struct PromptRequest: Sendable {
    public let system: String
    public let user: String
    public let imagePath: URL?
}

public let transcriptWindow: TimeInterval = 120

/// `question` is set on automatic triggers: the model may then decline with "—" if it isn't really a question.
public func buildPrompt(mode: Mode, context: CandidateContext, transcript: [Utterance], now: Date, imagePath: URL?,
                        question: String? = nil) -> PromptRequest {
    let task = switch mode {
    case .question:
        """
        Ответь на последний вопрос интервьюера как сильный инженер. Выведи ТОЛЬКО 3–5 тезисов, каждый с новой строки и с «• ».
        Тезис — до 15 слов: ключевые слова и конкретика (причина, механизм, команда, цифра), чтобы прочитать с одного взгляда.
        Никаких заголовков, вступлений, пересказа вопроса и пунктов сверх пяти, даже если просят перечислить много — дай 5 главных.
        Сначала самое важное — то, что интервьюер ждёт услышать.
        Вопросы о себе (опыт, «что нравится», STAR, конфликты): бери ситуацию и технологии из резюме. Любая цифра, срок, процент
        или название компании, которых нет в резюме дословно, — только как пропуск: [X%], [N минут], [компания]. Кандидату
        придётся отвечать на уточнения, поэтому выдуманная деталь хуже пропуска.

        """
    case .liveCode:
        "На скриншоте — задача live coding и/или текущий код. Дай рабочий код решения или следующего шага и 1–2 строки объяснения подхода и сложности."
    }
    let skip = question == nil ? "" : """

    Отвечай на любой вопрос интервьюера кандидату — технический, поведенческий, общий.
    Если последняя реплика не вопрос и не задание кандидату, выведи один символ «—» и больше ничего. Это, например:
    «Вы меня слышите?», «У тебя камера/свет/звук…», «Молодец, всё хорошо», «Давай потренируемся», «Это он сейчас думает?»,
    комментарии о поведении кандидата, болтовня между собой, бессвязные обрывки распознавания, ответы на вопросы кандидата.
    """
    let system = """
    Ты — незаметный подсказчик кандидата на техническом собеседовании. \(task)\(skip)
    Реплики «Кандидат» — это сам кандидат, его ответы; не отвечай на них, отвечай на вопросы «Интервьюера».
    Пиши на языке вопроса (обычно по-русски); по-английски — только термины и команды. Никаких других языков и алфавитов.
    Никогда не оценивай кандидата и не комментируй разговор.
    Расшифровка автоматическая: английские технические термины в ней могут быть искажены или записаны кириллицей («ум килд» = OOMKilled, «кубер» = Kubernetes). Восстанавливай их по звучанию и контексту и пиши правильно.

    РЕЗЮМЕ:
    \(context.resume)

    ВАКАНСИЯ:
    \(context.job)
    """
    let user = transcript
        .filter { now.timeIntervalSince($0.at) <= transcriptWindow }
        .map { "\($0.speaker == .interviewer ? "Интервьюер" : "Кандидат"): \($0.text)" }
        .joined(separator: "\n")
    var body = user.isEmpty ? "(разговор пока пуст)" : user
    if let question { body += "\n\nВопрос интервьюера: \(question)" }
    return PromptRequest(system: system, user: body, imagePath: imagePath)
}

public func isSkipAnswer(_ text: String) -> Bool {
    ["—", "-", "–"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Safety net for model quirks: drops CJK/kana/hangul glyphs that leak into Russian answers, and cuts bullet answers
/// to 5 points (the panel is read at a glance). Code answers are left intact apart from glyph removal.
public func sanitizeHint(_ text: String) -> String {
    let foreign: (Unicode.Scalar) -> Bool = { s in
        [0x1100...0x11FF, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF].contains { $0.contains(Int(s.value)) }
    }
    var inCode = false, bullets = 0, out: [String] = []
    for line in text.components(separatedBy: "\n") {
        if line.hasPrefix("```") { inCode.toggle(); out.append(line); continue }
        var l = String(String.UnicodeScalarView(line.unicodeScalars.filter { !foreign($0) }))
        if !inCode {
            while l.contains("  ") { l = l.replacingOccurrences(of: "  ", with: " ") }
            l = l.replacingOccurrences(of: " ,", with: ",")
            if l.hasPrefix("•") || l.hasPrefix("- ") || l.hasPrefix("* ") {
                bullets += 1
                if bullets > 5 && !text.contains("```") { break }
            }
        }
        out.append(l)
    }
    return out.joined(separator: "\n")
}
