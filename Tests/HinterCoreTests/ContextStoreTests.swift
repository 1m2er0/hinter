import Testing
import AppKit
@testable import HinterCore

private func tmp() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
private func file(_ dir: URL, _ name: String, _ text: String) -> URL {
    let u = dir.appendingPathComponent(name); try! text.write(to: u, atomically: true, encoding: .utf8); return u
}

@Test func emptyWhenNoFiles() throws {
    let c = try ContextStore(root: tmp()).load()
    #expect(c.resume == "" && c.job == "")
}

@Test func defaultsAndOverride() throws {
    let root = tmp(), src = tmp()
    let store = ContextStore(root: root)
    try store.setDefault(resume: file(src, "r.md", "RESUME"), job: file(src, "j.md", "JOB"))
    #expect(try store.load() == CandidateContext(resume: "RESUME", job: "JOB"))
    let other = file(src, "j2.md", "OTHER JOB")
    #expect(try store.load(jobOverride: other) == CandidateContext(resume: "RESUME", job: "OTHER JOB"))
    #expect(try store.load().job == "JOB")
}

@Test @MainActor func pdfOverrideIsReadAsText() throws {
    let v = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
    v.string = "Swift engineer"
    let u = tmp().appendingPathComponent("cv.pdf")
    try v.dataWithPDF(inside: v.bounds).write(to: u)
    #expect(try ContextStore(root: tmp()).load(resumeOverride: u).resume.contains("Swift engineer"))
}
