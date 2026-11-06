import Foundation

/// Energy-based VAD: cuts 16 kHz mono audio into utterances at ≥0.5 s pauses (max 10 s) for Whisper.
/// shortcut: fixed RMS threshold, no noise adaptation; upgrade to whisper's Silero VAD if noisy rooms cause junk segments.
public final class SpeechSegmenter {
    let frame: Int, threshold: Float
    let silenceFrames: Int, maxFrames: Int, minVoiced: Int, pad: Int
    var rest: [Float] = []
    var preroll: [[Float]] = []
    var seg: [[Float]] = []
    var voiced = 0, silent = 0

    /// maxLength 10 s matches whisper-server's `-ac 512` window (≈10.24 s).
    public init(sampleRate: Double = 16_000, silence: TimeInterval = 0.5, maxLength: TimeInterval = 10, threshold: Float = 0.01) {
        frame = Int(sampleRate * 0.02)
        self.threshold = threshold
        silenceFrames = Int(silence / 0.02)
        maxFrames = Int(maxLength / 0.02)
        minVoiced = Int(0.25 / 0.02)
        pad = 5 // 0.1 s kept before and after speech
    }

    public var isSpeaking: Bool { !seg.isEmpty }

    public func push(_ samples: [Float]) -> [[Float]] {
        var out: [[Float]] = []
        rest += samples
        var i = 0
        while i + frame <= rest.count {
            let f = Array(rest[i..<i + frame])
            i += frame
            let rms = (f.reduce(0) { $0 + $1 * $1 } / Float(frame)).squareRoot()
            let isVoice = rms > threshold
            if seg.isEmpty {
                if isVoice { seg = preroll + [f]; voiced = 1; silent = 0; preroll = [] }
                else { preroll.append(f); if preroll.count > pad { preroll.removeFirst() } }
                continue
            }
            seg.append(f)
            if isVoice { voiced += 1; silent = 0 } else { silent += 1 }
            if silent >= silenceFrames || seg.count >= maxFrames {
                if voiced >= minVoiced { out.append(Array(seg.dropLast(max(0, silent - pad)).joined())) }
                seg = []; voiced = 0; silent = 0
            }
        }
        rest.removeFirst(i)
        return out
    }
}

/// 16-bit PCM mono WAV.
public func wavData(_ samples: [Float], sampleRate: Int) -> Data {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let bytes = UInt32(samples.count * 2)
    d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(bytes)
    for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * Float(Int16.max)))) }
    return d
}

// Whisper invents these on silence/noise (trained on subtitled video).
private let hallucinations = ["продолжение следует", "субтитры", "dimatorzok", "редактор субтитров", "спасибо за просмотр",
                              "thanks for watching", "subtitles by", "amara.org"]
private let exactJunk: Set<String> = ["thank you.", "thank you", "спасибо.", "you", ".", "...", "конец", "конец."]

public func cleanWhisperText(_ raw: String) -> String? {
    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let low = t.lowercased()
    if t.isEmpty || exactJunk.contains(low) || hallucinations.contains(where: low.contains) { return nil }
    if (t.hasPrefix("[") && t.hasSuffix("]")) || (t.hasPrefix("(") && t.hasSuffix(")")) { return nil }
    return t
}

// Context terms first (most specific), then common backend/DevOps terms that Russian speech mangles.
private let commonTerms = ["Kubernetes", "OOMKilled", "CrashLoopBackOff", "ErrorBackOff", "ImagePullBackOff", "Pod", "kubectl", "Helm",
                           "Docker", "Kafka", "Redis", "PostgreSQL", "gRPC", "REST", "goroutine", "mutex", "deadlock", "race condition",
                           "garbage collector", "Prometheus", "Grafana", "Terraform", "CI/CD", "rollback", "latency", "throughput"]

/// Whisper's initial prompt biases spelling toward these terms; it is capped (~224 tokens), so keep it under 600 chars.
public func whisperPrompt(_ ctx: CandidateContext) -> String {
    let found = (ctx.resume + "\n" + ctx.job).matches(of: /[A-Za-z][A-Za-z0-9+#.\/\-]{1,40}/)
        .map { String($0.output).trimmingCharacters(in: CharacterSet(charactersIn: ".-/")) }
    var seen = Set<String>(), terms: [String] = [], length = 0
    for t in found + commonTerms where t.count >= 2 && seen.insert(t.lowercased()).inserted {
        if length + t.count + 2 > 560 { break }
        terms.append(t); length += t.count + 2
    }
    return "Техническое собеседование. " + terms.joined(separator: ", ") + "."
}

public enum WhisperError: Error, Equatable { case notInstalled, modelMissing(String), notReady, http(Int) }

/// Local whisper.cpp server on 127.0.0.1 — audio never leaves the machine.
public final class WhisperServer: @unchecked Sendable {
    let model: URL
    let port: Int
    private var process: Process?
    var base: URL { URL(string: "http://127.0.0.1:\(port)")! }

    public init(model: URL, port: Int = 18_178) { self.model = model; self.port = port }

    public var isRunning: Bool { process?.isRunning == true }

    public func start() async throws {
        if isRunning { return }
        // A server left over from a crashed run still holds the port: reuse it.
        if (try? await URLSession.shared.data(from: base))?.1 != nil { return }
        guard let bin = findBinary("whisper-server") else { throw WhisperError.notInstalled }
        guard FileManager.default.fileExists(atPath: model.path) else { throw WhisperError.modelMissing(model.path) }
        let p = Process()
        p.executableURL = bin
        p.arguments = ["-m", model.path, "--host", "127.0.0.1", "--port", "\(port)", "-nt", "-t", "4", // compute is on the GPU; extra CPU threads only add heat
                       "-ac", "512"] // encoder window ≈10 s instead of 30 s: ~3x faster on M3 (1.5 s → 0.45 s)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice // a full stderr pipe would block it; we only need readiness
        try p.run()
        process = p
        for _ in 0..<120 { // model load takes a few seconds
            if !p.isRunning { process = nil; throw WhisperError.notReady } // e.g. port taken
            if (try? await URLSession.shared.data(from: base))?.1 != nil { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        stop()
        throw WhisperError.notReady
    }

    public func stop() { process?.terminate(); process = nil }

    public func transcribe(_ wav: Data, language: String, prompt: String) async throws -> String {
        let boundary = "hh-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("language", language); field("prompt", prompt); field("temperature", "0"); field("response_format", "json")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var r = URLRequest(url: base.appendingPathComponent("inference"))
        r.httpMethod = "POST"
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.upload(for: r, from: body)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw WhisperError.http(h.statusCode) }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["text"] as? String ?? ""
    }
}
