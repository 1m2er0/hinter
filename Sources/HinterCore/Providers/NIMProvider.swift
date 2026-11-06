import Foundation

public struct NIMProvider: Provider {
    public let name = "NIM"
    // 2026-11-05: lightning-30b-a3b was fast but wrong on ops questions (df/du, load average); super-vl has the same
    // ~0.5s first token and correct answers, and also handles screenshots.
    static let textModel = "nvidia/nemotron-3.5-super-vl-120b-a12b"
    static let visionModel = "nvidia/nemotron-3.5-super-vl-120b-a12b"
    static let endpoint = URL(string: "https://integrate.api.nvidia.com/v1/chat/completions")!

    let key: String?
    let model: String?
    /// `key` overrides the Keychain lookup, `model` the text model (live tests).
    public init(key: String? = nil, model: String? = nil) { self.key = key; self.model = model }

    public func stream(_ req: PromptRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    guard let key = try key ?? Keychain.get(account: "nim-api-key").flatMap({ String(data: $0, encoding: .utf8) })
                    else { throw ProviderError.missingKey }
                    var r = URLRequest(url: Self.endpoint)
                    r.httpMethod = "POST"
                    r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    r.timeoutInterval = 30
                    r.httpBody = try JSONSerialization.data(withJSONObject: try Self.body(req, textModel: model ?? Self.textModel))
                    let (bytes, resp) = try await URLSession.shared.bytes(for: r)
                    if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw ProviderError.failed("NIM HTTP \(h.statusCode)") }
                    for try await line in bytes.lines {
                        switch try parseSSELine(line) {
                        case .text(let t)?: cont.yield(t)
                        case .done?: cont.finish(); return
                        case nil: continue
                        }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    static func body(_ req: PromptRequest, textModel: String) throws -> [String: Any] {
        var user: Any = req.user
        if let img = req.imagePath {
            let b64 = try Data(contentsOf: img).base64EncodedString()
            user = [["type": "text", "text": req.user],
                    ["type": "image_url", "image_url": ["url": "data:image/\(img.pathExtension == "png" ? "png" : "jpeg");base64,\(b64)"]]]
        }
        return ["model": req.imagePath == nil ? textModel : visionModel, "stream": true,
                // Low temperature: at the default, super-vl sprinkled CJK/Spanish tokens into Russian answers.
                "temperature": 0.3, "top_p": 0.9, "max_tokens": req.imagePath == nil ? 600 : 1500,
                "chat_template_kwargs": ["enable_thinking": false],
                "messages": [["role": "system", "content": req.system], ["role": "user", "content": user]]]
    }
}
