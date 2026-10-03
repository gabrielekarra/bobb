import Foundation

/// RFC header continuations and exact conversation identities. Subjects
/// and display names never serve as proof that a reminder was answered.
public struct MailHeaders: Sendable, Equatable {
    public var inReplyTo = ""
    public var references: [String] = []
    public var listId = ""
    public var automatic = false
    public init() {}

    public init(raw: String) {
        var fields: [String: String] = [:]
        var key = ""
        for line in raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t"), !key.isEmpty {
                fields[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                key = String(line[..<colon]).lowercased()
                fields[key, default: ""] += String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            } else { key = "" }
        }
        func ids(_ value: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: #"<([^<>\s]+)>"#) else { return [] }
            return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap {
                Range($0.range(at: 1), in: value).map { String(value[$0]) }
            }
        }
        inReplyTo = ids(fields["in-reply-to"] ?? "").last ?? ""
        references = Array(ids(fields["references"] ?? "").suffix(30))
        listId = fields["list-id"] ?? ""
        automatic = fields["auto-submitted"].map { $0.lowercased() != "no" && !$0.isEmpty } ?? false
        if ["bulk", "list", "junk"].contains(fields["precedence"]?.lowercased() ?? "") { automatic = true }
    }

    public static func canonicalID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    }
}

public enum MailDraftChecks {
    /// Fast, explainable checks over authored text only; quoted history and
    /// signatures have already been removed by MailComposeSnapshot.
    public static func issues(draft: String, subject: String, recipients: [String], attachmentCount: Int) -> [String] {
        var issues: [String] = []
        let attachment = #"(?i)\b(?:in allegato|ti allego|trovi allegat[oaie]|ho allegato|attached|i attach|please find attached)\b"#
        let negated = #"(?i)\b(?:non.{0,18}alleg|nessun alleg|not.{0,18}attach|no attachment|senza allegat)"#
        if attachmentCount == 0, draft.range(of: attachment, options: .regularExpression) != nil,
           draft.range(of: negated, options: .regularExpression) == nil { issues.append("attachment") }
        if subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("subject") }
        if recipients.isEmpty { issues.append("recipient") }
        if draft.range(of: #"(?i)\[(?:name|nome|date|data|insert|inserisci|todo)[^\]]*\]|\b(?:TODO|TBD|XXX)\b"#, options: .regularExpression) != nil { issues.append("placeholder") }
        return issues
    }
}
