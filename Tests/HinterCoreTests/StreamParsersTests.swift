import Testing
@testable import HinterCore

@Test func sse() throws {
    #expect(try parseSSELine(#"data: {"choices":[{"delta":{"content":"Hi"}}]}"#) == .text("Hi"))
    #expect(try parseSSELine(#"data: {"choices":[{"delta":{"reasoning_content":"hmm"}}]}"#) == nil)
    #expect(try parseSSELine("data: [DONE]") == .done)
    #expect(try parseSSELine(": keep-alive") == nil)
    #expect(try parseSSELine("") == nil)
}

@Test func claudeStreamJSON() throws {
    #expect(try parseClaudeStreamJSONLine(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Mu"}}}"#) == .text("Mu"))
    #expect(try parseClaudeStreamJSONLine(#"{"type":"assistant","message":{"content":[{"type":"text","text":"dup"}]}}"#) == nil)
    #expect(try parseClaudeStreamJSONLine(#"{"type":"result","subtype":"success","is_error":false,"result":"x"}"#) == .done)
    #expect(throws: ProviderError.failed("Not logged in · Please run /login")) {
        try parseClaudeStreamJSONLine(#"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"#)
    }
    #expect(try parseClaudeStreamJSONLine("garbage") == nil)
}

@Test func codexJSON() throws {
    #expect(try parseCodexJSONLine(#"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Answer"}}"#) == .text("Answer"))
    #expect(try parseCodexJSONLine(#"{"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":"think"}}"#) == nil)
    #expect(try parseCodexJSONLine(#"{"type":"turn.completed","usage":{}}"#) == .done)
    #expect(throws: ProviderError.failed("boom")) { try parseCodexJSONLine(#"{"type":"turn.failed","error":{"message":"boom"}}"#) }
    #expect(throws: ProviderError.failed("bad")) { try parseCodexJSONLine(#"{"type":"error","message":"bad"}"#) }
}
