import Foundation

public enum StreamEvent: Equatable, Sendable { case text(String), done }

public enum ProviderError: Error, Equatable, Sendable {
    case notInstalled(String)
    case missingKey
    case failed(String)
}

private func json(_ s: some StringProtocol) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
}

/// OpenAI-compatible SSE (NIM). Reasoning deltas are ignored.
public func parseSSELine(_ line: String) throws -> StreamEvent? {
    guard line.hasPrefix("data: ") else { return nil }
    let payload = line.dropFirst(6)
    if payload == "[DONE]" { return .done }
    guard let o = json(payload) else { return nil }
    if let e = o["error"] as? [String: Any] { throw ProviderError.failed(e["message"] as? String ?? "\(e)") }
    let delta = ((o["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])
    guard let t = delta?["content"] as? String, !t.isEmpty else { return nil }
    return .text(t)
}

/// `claude -p --output-format stream-json --include-partial-messages`: only text deltas, so full messages aren't duplicated.
public func parseClaudeStreamJSONLine(_ line: String) throws -> StreamEvent? {
    guard let o = json(line) else { return nil }
    switch o["type"] as? String {
    case "stream_event":
        let d = (o["event"] as? [String: Any])?["delta"] as? [String: Any]
        guard d?["type"] as? String == "text_delta", let t = d?["text"] as? String else { return nil }
        return .text(t)
    case "result":
        if o["is_error"] as? Bool == true { throw ProviderError.failed(o["result"] as? String ?? "claude error") }
        return .done
    default: return nil
    }
}

/// `codex exec --json`: emits whole agent messages, not token deltas.
public func parseCodexJSONLine(_ line: String) throws -> StreamEvent? {
    guard let o = json(line) else { return nil }
    switch o["type"] as? String {
    case "item.completed":
        let item = o["item"] as? [String: Any]
        guard item?["type"] as? String == "agent_message", let t = item?["text"] as? String else { return nil }
        return .text(t)
    case "turn.completed": return .done
    case "turn.failed": throw ProviderError.failed(((o["error"] as? [String: Any])?["message"] as? String) ?? "codex failed")
    case "error": throw ProviderError.failed(o["message"] as? String ?? "codex error")
    default: return nil
    }
}
