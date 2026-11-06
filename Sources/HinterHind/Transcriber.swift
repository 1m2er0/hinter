import AVFoundation
import Speech
import HinterCore

/// One audio channel → utterances. `onResult(utterance, isFinal)`; `onActivity` fires while speech is heard but not yet transcribed.
protocol SpeechChannel: AnyObject {
    var onActivity: ((Date) -> Void)? { get set }
    func start(onResult: @escaping (Utterance, Bool) -> Void) async throws
    func feed(_ buf: AVAudioPCMBuffer)
    func stop() async
}

/// Apple on-device fallback. DictationTranscriber because SpeechTranscriber has no ru_RU.
final class Transcriber: SpeechChannel {
    var onActivity: ((Date) -> Void)?
    let speaker: Speaker
    private let module: DictationTranscriber
    private let analyzer: SpeechAnalyzer
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var resultsTask: Task<Void, Never>?

    init(locale: Locale, speaker: Speaker) {
        self.speaker = speaker
        module = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                      reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
        analyzer = SpeechAnalyzer(modules: [module])
    }

    func start(onResult: @escaping (Utterance, Bool) -> Void) async throws {
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) { try await req.downloadAndInstall() }
        format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        input = cont
        let speaker = speaker, module = module
        resultsTask = Task {
            do {
                for try await r in module.results {
                    let text = String(r.text.characters).trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { onResult(Utterance(speaker: speaker, text: text, at: Date()), r.isFinal) }
                }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)
    }

    func feed(_ buf: AVAudioPCMBuffer) {
        guard let input, let format else { return }
        if buf.format == format { input.yield(AnalyzerInput(buffer: buf)); return }
        if converter?.inputFormat != buf.format { converter = AVAudioConverter(from: buf.format, to: format) }
        guard let converter else { return }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * format.sampleRate / buf.format.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return }
        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return buf
        }
        if err == nil, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
    }

    func stop() async {
        input?.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
    }
}
