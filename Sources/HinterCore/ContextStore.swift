import Foundation
import PDFKit

public struct CandidateContext: Equatable, Sendable {
    public var resume: String
    public var job: String
    public init(resume: String, job: String) { self.resume = resume; self.job = job }
}

/// Default resume/job live in `root/context/`; per-call overrides are optional.
public final class ContextStore {
    let dir: URL
    public init(root: URL) { dir = root.appendingPathComponent("context") }

    public func load(resumeOverride: URL? = nil, jobOverride: URL? = nil) throws -> CandidateContext {
        CandidateContext(resume: try read(resumeOverride ?? dir.appendingPathComponent("resume.md")),
                         job: try read(jobOverride ?? dir.appendingPathComponent("job.md")))
    }

    public func setDefault(resume: URL?, job: URL?) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (src, name) in [(resume, "resume.md"), (job, "job.md")] {
            guard let src else { continue }
            try read(src).write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    private func read(_ u: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: u.path) else { return "" }
        if u.pathExtension.lowercased() == "pdf" {
            guard let text = PDFDocument(url: u)?.string else { throw CocoaError(.fileReadCorruptFile) }
            return text
        }
        return try String(contentsOf: u, encoding: .utf8)
    }
}
