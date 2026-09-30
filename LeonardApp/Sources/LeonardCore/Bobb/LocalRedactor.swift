import Foundation

/// Redaction is local and reversible only within this request. Tokens use
/// a random namespace so a page cannot plant a token that restores a secret.
public struct LocalRedactor: Sendable {
    private var replacements: [String: String] = [:]
    private let namespace = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    public init() {}
    public mutating func redact(_ input: String, privateTerms: [String] = []) -> String {
        var value = input
        for term in Set(privateTerms).sorted(by: { $0.count > $1.count }) where term.count >= 2 {
            value = replace(value, pattern: NSRegularExpression.escapedPattern(for: term))
        }
        let patterns = [
            #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            #"(?<![A-Za-z0-9_])(?:\+\d{1,3}[ .-]?)?(?:\d[ .()-]?){8,16}\d(?![A-Za-z0-9_])"#,
            #"\b(?:sk-|ghp_|github_pat_|xox[baprs]-)[A-Za-z0-9_-]{8,}\b"#,
            #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#,
            #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#,
            #"\b[A-Z]{2}\d{2}[A-Z0-9 ]{11,30}\b"#,
            #"(?m)(?:password|passwd|secret|api[ _-]?key|token|codice|otp)\s*[:=]\s*\S+"#,
            #"(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----"#,
        ]
        for pattern in patterns { value = replace(value, pattern: pattern) }
        return value
    }
    public func restore(_ input: String) -> String {
        replacements.reduce(input) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }
    private mutating func replace(_ input: String, pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return input }
        var out = input
        for match in regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            let original = String(out[range])
            let token = "[PRIVATE_\(namespace)_\(replacements.count)]"
            replacements[token] = original
            out.replaceSubrange(range, with: token)
        }
        return out
    }
}
