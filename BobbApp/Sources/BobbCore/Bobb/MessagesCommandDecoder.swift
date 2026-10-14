import Foundation

/// Read only bounded command strings from Messages' legacy typed streams.
/// No archived classes are instantiated. Unsupported formats fail closed.
public enum MessagesCommandDecoder {
    public static func archivedStrings(_ data: Data) -> [String] {
        guard data.count <= 65536 else { return [] }
        let bytes = [UInt8](data), header = Array("streamtyped".utf8)
        guard bytes.count > 13, bytes[0] == 4, bytes[1] == 11, Array(bytes[2..<13]) == header else { return [] }
        var results: [String] = []
        for i in 13..<max(13, bytes.count - 3) where bytes[i] == 0x84 && bytes[i + 1] == 1 && bytes[i + 2] == 0x2b {
            var start = i + 4
            let tag = bytes[i + 3]; var length = Int(tag)
            if tag == 0x81, start + 2 <= bytes.count { length = Int(bytes[start]) | Int(bytes[start + 1]) << 8; start += 2 }
            else if tag == 0x82, start + 4 <= bytes.count { length = (0..<4).reduce(0) { $0 | Int(bytes[start + $1]) << (8 * $1) }; start += 4 }
            else if tag >= 0x80 { continue }
            guard length > 0, length <= 32000, start + length <= bytes.count,
                  let value = String(bytes: bytes[start..<start + length], encoding: .utf8), !value.contains("\0") else { continue }
            results.append(value)
        }
        return results
    }
    public static func decode(plain: String?, attributedBody: Data?) -> String? {
        var candidates: [String] = []
        if let plain { candidates.append(plain) }
        if let data = attributedBody { candidates += archivedStrings(data) }
        let commands = Set(candidates.filter { $0.hasPrefix("/bobb ") && $0.count <= 4000 }.map { String($0.dropFirst(6)) })
        return commands.count == 1 ? commands.first : nil
    }
}
