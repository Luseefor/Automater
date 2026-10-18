import Foundation
import CryptoKit

public struct ClipboardEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, image, files }
    public var id: String
    public var kind: Kind
    public var text: String
    public var paths: [String]
    public var imageFilename: String?
    public var copiedAt: Date
    public var sourceName: String
    public var sourceBundleID: String?
    public var isPinned: Bool
    public init(kind: Kind = .text, text: String = "", paths: [String] = [], imageData: Data? = nil,
                copiedAt: Date = Date(), sourceName: String = "", sourceBundleID: String? = nil, isPinned: Bool = false) {
        self.kind = kind; self.text = text; self.paths = paths; self.copiedAt = copiedAt
        self.sourceName = sourceName; self.sourceBundleID = sourceBundleID; self.isPinned = isPinned
        var canonical = Data(kind.rawValue.utf8)
        canonical.append(imageData ?? Data((kind == .files ? paths.joined(separator: "\u{0}") : text).utf8))
        id = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        imageFilename = kind == .image ? id + ".png" : nil
    }
    public var title: String {
        switch kind {
        case .text:
            return String(text.split(whereSeparator: { $0.isNewline }).first.map(String.init)?.prefix(120) ?? "Copied text")
        case .image: return "Copied image"
        case .files: return paths.count == 1 ? URL(fileURLWithPath: paths[0]).lastPathComponent : "\(paths.count) files"
        }
    }
    public var subtitle: String {
        switch kind {
        case .text: return "\(text.count.formatted()) characters"
        case .image: return "Image"
        case .files: return paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
        }
    }
    public var icon: String {
        switch kind {
        case .text: return text.hasPrefix("https://") || text.hasPrefix("http://") ? "link" : "text.alignleft"
        case .image: return "photo"
        case .files: return "doc.on.doc"
        }
    }
}

public struct ClipboardHistory: Codable, Equatable, Sendable {
    public var version = 1
    public var entries: [ClipboardEntry] = []
    public init(entries: [ClipboardEntry] = []) { self.entries = entries }
    public mutating func insert(_ entry: ClipboardEntry, limit: Int = 100) {
        var entry = entry
        if let previous = entries.first(where: { $0.id == entry.id }) { entry.isPinned = previous.isPinned }
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        while entries.count > max(1, limit) {
            if let index = entries.lastIndex(where: { !$0.isPinned }) { entries.remove(at: index) }
            else { break }
        }
    }
    public mutating func clear(keepingPinned: Bool) { entries.removeAll { !keepingPinned || !$0.isPinned } }
}

public struct ClipboardRepository: Sendable {
    public var directory: URL
    public var url: URL { directory.appendingPathComponent("history.json") }
    public var assets: URL { directory.appendingPathComponent("images", isDirectory: true) }
    public init(directory: URL = Storage.appDir.appendingPathComponent("Clipboard", isDirectory: true)) { self.directory = directory }
    public func load() throws -> ClipboardHistory {
        guard FileManager.default.fileExists(atPath: url.path) else { return ClipboardHistory() }
        let history = try JSONDecoder().decode(ClipboardHistory.self, from: Data(contentsOf: url))
        guard history.version == 1 else { throw ClipboardError("This clipboard history was saved by a newer version of Automater.") }
        return history
    }
    public func save(_ history: ClipboardHistory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try JSONEncoder().encode(history).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func saveImage(_ data: Data, for entry: ClipboardEntry) throws {
        guard let name = entry.imageFilename, name == entry.id + ".png", !name.contains("/") else { return }
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = assets.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func imageURL(for entry: ClipboardEntry) -> URL? {
        guard let name = entry.imageFilename, name == entry.id + ".png", !name.contains("/") else { return nil }
        return assets.appendingPathComponent(name)
    }
    public func pruneImages(keeping history: ClipboardHistory) throws {
        guard FileManager.default.fileExists(atPath: assets.path) else { return }
        let names = Set(history.entries.compactMap(\.imageFilename))
        for url in try FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil)
            where url.pathExtension == "png" && !names.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

public struct ClipboardError: LocalizedError {
    public var errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}
