import AVFoundation
import HinterCore

/// Cuts the channel into utterances and transcribes each with the local whisper-server, in order.
final class WhisperTranscriber: SpeechChannel {
    let speaker: Speaker
    var onActivity: ((Date) -> Void)?
    private let server: WhisperServer
    private let language: String
    private let prompt: String
    private let segmenter = SpeechSegmenter()
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var segments: AsyncStream<[Float]>.Continuation?
    private var worker: Task<Void, Never>?
    private let queue = DispatchQueue(label: "hh.whisper.segmenter") // segmenter isn't thread-safe; feed comes from the audio queue

    init(server: WhisperServer, locale: Locale, speaker: Speaker, prompt: String) {
        self.server = server
        self.speaker = speaker
        self.prompt = prompt
        language = locale.identifier.hasPrefix("ru") ? "ru" : "en"
    }

    func start(onResult: @escaping (Utterance, Bool) -> Void) async throws {
        try await server.start()
        let (stream, cont) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(8))
        segments = cont
        let server = server, language = language, prompt = prompt, speaker = speaker
        worker = Task {
            for await seg in stream {
                guard let raw = try? await server.transcribe(wavData(seg, sampleRate: 16_000), language: language, prompt: prompt),
                      let text = cleanWhisperText(raw) else { continue }
                onResult(Utterance(speaker: speaker, text: text, at: Date()), true)
            }
        }
    }

    func feed(_ buf: AVAudioPCMBuffer) {
        guard let mono = convert(buf) else { return }
        queue.async { [self] in
            for seg in segmenter.push(mono) { segments?.yield(seg) }
            if segmenter.isSpeaking { onActivity?(Date()) }
        }
    }

    func stop() async {
        segments?.finish()
        worker?.cancel()
    }

    private func convert(_ buf: AVAudioPCMBuffer) -> [Float]? {
        if converter?.inputFormat != buf.format { converter = AVAudioConverter(from: buf.format, to: target) }
        guard let converter else { return nil }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 16_000 / buf.format.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return buf
        }
        guard err == nil, let ch = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }
}
