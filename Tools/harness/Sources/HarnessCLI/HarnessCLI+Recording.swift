import Foundation
import HarnessCore

extension HarnessCLI {
    static func handleRecording(_ args: [String]) throws -> Int32 {
        guard let verb = args.first, let input = flagValue(args, flag: "--input") else { throw RecordingArchiveError.invalid }
        let source = URL(fileURLWithPath: input)
        if verb == "protect" { try RecordingArchive.protectLegacy(at: source); print("Verified encrypted conversion complete. No plaintext migration backup was retained; this does not securely erase SSD data."); return 0 }
        let document = try RecordingArchive.read(source), review = try AsciicastExport.review(document)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Candidate: Encodable { var id: Int, reason: String, timeMs: Int, context: String }
        struct Report: Encodable { var protection: String, warnings: [String], candidates: [Candidate], outputBytes: Int }
        let report = Report(protection: document.protection, warnings: review.warnings, candidates: review.candidates.map { Candidate(id: $0.id, reason: $0.reason, timeMs: $0.timeMs, context: $0.context) }, outputBytes: review.outputBytes)
        if verb == "review" { print(String(decoding: try encoder.encode(report), as: UTF8.self)); return 0 }
        guard verb == "export", args.contains("--reviewed"), let output = flagValue(args, flag: "--output") else {
            throw NSError(domain: "HarnessCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Review with recording review --input FILE, then use recording export --input FILE --output FILE.cast --reviewed. Candidate masking is heuristic; exported files are plaintext."])
        }
        var literals: [String] = []
        if let path = flagValue(args, flag: "--redactions-file") {
            guard let data = try PrivateFile.read(URL(fileURLWithPath: path), maximumBytes: 256 << 10) else { throw RecordingArchiveError.invalid }
            literals = try JSONDecoder().decode([String].self, from: data)
        }
        let data = try AsciicastExport.render(review, additionalLiterals: literals)
        try AsciicastExport.save(data, to: URL(fileURLWithPath: output))
        for warning in review.warnings { fputs(warning + "\n", harnessStderr) }
        print("Saved reviewed plaintext asciicast: " + output); return 0
    }
}
