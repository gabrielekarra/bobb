import AppKit
import CryptoKit
import PDFKit
import BobbCore

/// All paths are relative to folders selected through the native picker.
/// Existing files are changed only after listing/reading an exact version.
@MainActor
final class FileAppTools {
    private let folders: () -> [FileFolder]
    private var observed: [String: (folder: String, path: String, version: String)] = [:]
    init(folders: @escaping () -> [FileFolder]) { self.folders = folders }
    nonisolated static func root(_ folder: FileFolder) throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: folder.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale, url.isFileURL else { throw NativeAppTools.Failure.unavailable("Choose this folder again; its access bookmark expired.") }
        return url
    }
    private func version(_ url: URL) throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let value = "\(attrs[.systemFileNumber] ?? "")|\(attrs[.size] ?? "")|\(modified)"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func snapshot(_ url: URL, folder: FileFolder, root: URL) throws -> JSONValue {
        let relative = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let revision = try version(url), id = folder.id + ":" + relative
        observed[id] = (folder.id, relative, revision)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        return ["file_id": .string(id), "folder_id": .string(folder.id), "path": .string(relative), "name": .string(url.lastPathComponent),
            "version": .string(revision), "directory": .bool(values.isDirectory == true), "bytes": .number(Double(values.fileSize ?? 0))]
    }
    func execute(_ tool: AppTool, _ args: JSONValue) throws -> JSONValue {
        if tool.id == "files.folders" { return .array(folders().map { ["folder_id": .string($0.id), "name": .string($0.name), "indexed": .bool($0.indexEnabled)] }) }
        let existing = args["file_id"]?.stringValue.flatMap { observed[$0] }
        let folderID = existing?.folder ?? args["folder_id"]?.stringValue ?? ""
        guard let folder = folders().first(where: { $0.id == folderID }) else { throw NativeAppTools.Failure.unavailable("Choose an exact folder id from files.folders.") }
        let root = try Self.root(folder).standardizedFileURL.resolvingSymlinksInPath()
        let scoped = root.startAccessingSecurityScopedResource(); defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        if tool.id == "files.list" || tool.id == "files.search" {
            let relative = args["path"]?.stringValue ?? ""
            guard let directory = FileScope.resolve(relative, root: root) else { throw NativeAppTools.Failure.unavailable("The path is outside the selected folder.") }
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey]
            var items: [URL] = []
            var scanTruncated = false
            if tool.id == "files.list" { items = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) }
            else {
                guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { throw NativeAppTools.Failure.unavailable("Folder is unavailable.") }
                var count = 0
                let query = args["query"]?.stringValue ?? ""
                for case let url as URL in enumerator {
                    try Task.checkCancellation(); count += 1
                    if count > 5000 { scanTruncated = true; break }
                    if url.lastPathComponent.localizedCaseInsensitiveContains(query) { items.append(url) }
                }
            }
            items = items.filter { url in
                (try? url.resourceValues(forKeys: Set(keys)).isSymbolicLink) != true
                    && FileScope.resolve(String(url.path.dropFirst(root.path.count + 1)), root: root) != nil
            }.sorted { $0.path < $1.path }
            let offset = Int(args["offset"]?.numberValue ?? 0), limit = Int(args["limit"]?.numberValue ?? 25)
            let page = try items.dropFirst(offset).prefix(limit).map { try snapshot($0, folder: folder, root: root) }
            return ["items": .array(page), "total": .number(Double(items.count)), "has_more": .bool(offset + limit < items.count),
                "next_offset": .number(Double(offset + page.count)), "scan_truncated": .bool(scanTruncated)]
        }
        if tool.id == "files.create" {
            guard let path = args["path"]?.stringValue, !path.isEmpty, let url = FileScope.resolve(path, root: root),
                  !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { throw NativeAppTools.Failure.unavailable("Choose a new relative filename in an existing selected directory.") }
            let data = Data((args["text"]?.stringValue ?? "").utf8)
            try data.write(to: url, options: [.withoutOverwriting])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return ["status": "created", "file": try snapshot(url, folder: folder, root: root)]
        }
        guard let existing, let url = FileScope.resolve(existing.path, root: root),
              try version(url) == existing.version else { throw NativeAppTools.Failure.unavailable("List or read the file again; it changed or is unavailable.") }
        if tool.id == "files.read" {
            let text = try Self.text(url), offset = Int(args["offset"]?.numberValue ?? 0), count = Int(args["characters"]?.numberValue ?? 4000)
            return ["file": try snapshot(url, folder: folder, root: root), "text": .string(String(text.dropFirst(offset).prefix(count))),
                "total_characters": .number(Double(text.count)), "next_offset": .number(Double(min(text.count, offset + count))), "has_more": .bool(offset + count < text.count)]
        }
        guard args["expected_version"]?.stringValue == existing.version else { throw NativeAppTools.Failure.unavailable("Use the exact observed expected_version before changing a file.") }
        switch tool.id {
        case "files.replace":
            // Exact readback, atomic replacement; never reinterpret rich documents as plain text.
            guard Self.plainExtensions.contains(url.pathExtension.lowercased()) else { throw NativeAppTools.Failure.unavailable("Only plain text files can be replaced. Use the document's app for rich formats.") }
            let data = Data((args["text"]?.stringValue ?? "").utf8); try data.write(to: url, options: .atomic)
            guard try Data(contentsOf: url) == data else { throw NativeAppTools.Failure.unavailable("The write could not be read back.") }
            return ["status": "updated", "file": try snapshot(url, folder: folder, root: root)]
        case "files.move":
            guard let destination = args["destination"]?.stringValue.flatMap({ FileScope.resolve($0, root: root) }),
                  destination != root, destination != url, !FileManager.default.fileExists(atPath: destination.path) else { throw NativeAppTools.Failure.unavailable("Choose a new relative destination inside the same folder.") }
            try FileManager.default.moveItem(at: url, to: destination)
            return ["status": "moved", "file": try snapshot(destination, folder: folder, root: root)]
        case "files.trash":
            guard url != root else { throw NativeAppTools.Failure.unavailable("The selected root folder cannot be trashed.") }
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            guard !FileManager.default.fileExists(atPath: url.path) else { throw NativeAppTools.Failure.unavailable("Trash could not be verified.") }
            return ["status": "trashed", "file_id": args["file_id"]!]
        default: throw NativeAppTools.Failure.unavailable("Unknown file tool.")
        }
    }
    nonisolated static let plainExtensions: Set<String> = ["", "txt", "md", "csv", "tsv", "json", "jsonl", "yaml", "yml", "xml", "log", "swift", "py", "js", "ts", "css", "html", "sh"]
    nonisolated static func text(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 20_000_000 else { throw NativeAppTools.Failure.unavailable("Choose a regular document smaller than 20 MB.") }
        let ext = url.pathExtension.lowercased()
        let text: String
        if plainExtensions.contains(ext) {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard let value = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16), !value.contains("\0") else { throw NativeAppTools.Failure.unavailable("This file is not supported text.") }
            text = value
        } else if ext == "pdf" {
            guard let document = PDFDocument(url: url), !document.isLocked else { throw NativeAppTools.Failure.unavailable("The PDF is unavailable or encrypted.") }
            var pages: [String] = []; var characters = 0
            for i in 0..<min(document.pageCount, 500) {
                try Task.checkCancellation(); let page = document.page(at: i)?.string ?? ""; pages.append(page); characters += page.count
                guard characters <= 1_000_000 else { throw NativeAppTools.Failure.unavailable("This PDF exceeds the text extraction limit.") }
            }
            guard document.pageCount <= 500 else { throw NativeAppTools.Failure.unavailable("Choose a PDF with at most 500 pages.") }
            text = pages.joined(separator: "\n\n")
        } else if ["rtf", "docx", "odt"].contains(ext) {
            let type: NSAttributedString.DocumentType = ext == "rtf" ? .rtf : (ext == "docx" ? .officeOpenXML : .openDocument)
            text = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil).string
        } else { throw NativeAppTools.Failure.unavailable("Supported documents: plain text, PDF with text, RTF, DOCX and ODT. Use the owning app for other formats.") }
        guard text.count <= 1_000_000 else { throw NativeAppTools.Failure.unavailable("This document exceeds the text extraction limit.") }
        return text
    }
}
