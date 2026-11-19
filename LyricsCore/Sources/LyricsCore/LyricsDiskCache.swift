import Foundation

/// Lyrics kept on the phone, one small JSON file per song, so songs played before still have lyrics with no network.
/// ponytail: no size cap; at a few KB per song it takes thousands of songs to matter. Add pruning if it ever does.
public struct LyricsDiskCache: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let lrc: String
        public let instrumental: Bool

        public init(lrc: String, instrumental: Bool) { self.lrc = lrc; self.instrumental = instrumental }
    }

    let folder: URL

    public init(folder: URL) { self.folder = folder }

    public func load(_ id: String) -> Entry? {
        (try? Data(contentsOf: file(for: id))).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
    }

    public func save(_ entry: Entry, for id: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(entry).write(to: file(for: id), options: .atomic)
    }

    /// Percent-encoded, so IDs like "am:1234" and "am/1234" get safe, distinct names.
    func file(for id: String) -> URL {
        folder.appending(path: (id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id) + ".json")
    }
}
