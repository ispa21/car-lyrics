import Foundation

/// The track Spotify is playing, plus where playback was when sampled.
public struct NowPlaying: Equatable, Sendable {
    public let trackID: String
    public let title: String
    public let artists: [String]
    public let album: String
    public let durationMs: Int
    public let playback: PlaybackSnapshot
    /// The smallest album art Spotify offers; the card only needs a blurred thumbnail.
    public let artworkURL: URL?
    public var artist: String { artists.first ?? "" }

    public init(trackID: String, title: String, artists: [String], album: String, durationMs: Int, playback: PlaybackSnapshot,
                artworkURL: URL? = nil) {
        self.trackID = trackID; self.title = title; self.artists = artists
        self.album = album; self.durationMs = durationMs; self.playback = playback; self.artworkURL = artworkURL
    }
}

/// A Spotify track object, as found in currently-playing and queue responses.
private struct SpotifyItem: Decodable {
    struct Named: Decodable { let name: String }
    struct Album: Decodable {
        struct Image: Decodable { let url: URL; let width: Int? }
        let name: String
        let images: [Image]?
    }
    let id: String?
    let uri: String?
    let type: String?
    let name: String
    let duration_ms: Int
    let album: Album?
    let artists: [Named]?

    func nowPlaying(_ playback: PlaybackSnapshot) -> NowPlaying {
        NowPlaying(trackID: id ?? uri ?? name,  // local files have no id
                   title: name, artists: artists?.map(\.name) ?? [], album: album?.name ?? "",
                   durationMs: duration_ms, playback: playback,
                   artworkURL: album?.images?.min { ($0.width ?? .max) < ($1.width ?? .max) }?.url)
    }
}

/// Decodes `GET /v1/me/player/currently-playing`.
public enum SpotifyNowPlaying {
    private struct Response: Decodable {
        let is_playing: Bool
        let progress_ms: Int?
        let currently_playing_type: String?
        let item: SpotifyItem?
    }

    /// Returns nil when nothing usable is playing: an empty body (HTTP 204), an ad, an episode, or no item.
    /// `sampledAt` should be the midpoint of the request, which is when `progress_ms` was most likely true.
    public static func decode(_ data: Data, sampledAt: Date) throws -> NowPlaying? {
        guard !data.isEmpty else { return nil }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.currently_playing_type ?? "track" == "track", let item = response.item, let progress = response.progress_ms else { return nil }
        return item.nowPlaying(PlaybackSnapshot(progressMs: progress, sampledAt: sampledAt, isPlaying: response.is_playing, durationMs: item.duration_ms))
    }
}

/// Decodes `GET /v1/me/player/queue`: the upcoming tracks, podcasts skipped.
public enum SpotifyQueue {
    private struct Response: Decodable { let queue: [SpotifyItem] }

    public static func decode(_ data: Data) throws -> [NowPlaying] {
        try JSONDecoder().decode(Response.self, from: data).queue
            .filter { $0.type ?? "track" == "track" }
            .map { $0.nowPlaying(PlaybackSnapshot(progressMs: 0, sampledAt: .distantPast, isPlaying: false, durationMs: $0.duration_ms)) }
    }
}

/// The paged library endpoints used to save lyrics for offline. Liked Songs (`GET /me/tracks`) hold each song under
/// "track"; playlist contents (`GET /playlists/{id}/items`) hold it under "item" since February 2026 ("track" is kept
/// but deprecated). Podcasts and removed songs are skipped.
public enum SpotifyLibrary {
    public struct Page<Item: Sendable>: Sendable {
        public let items: [Item]
        public let next: URL?
    }

    public struct Playlist: Equatable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let ownerID: String
        public let collaborative: Bool
        public let total: Int
    }

    public static func tracks(_ data: Data) throws -> Page<NowPlaying> {
        struct Entry: Decodable { let item: SpotifyItem?; let track: SpotifyItem? }
        struct Response: Decodable { let items: [Entry]; let next: URL? }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let songs = response.items.compactMap { $0.item ?? $0.track }
            .filter { $0.type ?? "track" == "track" }
            .map { $0.nowPlaying(PlaybackSnapshot(progressMs: 0, sampledAt: .distantPast, isPlaying: false, durationMs: $0.duration_ms)) }
        return Page(items: songs, next: response.next)
    }

    /// `GET /me/playlists`. The song count moved from "tracks.total" to "items.total" in February 2026.
    public static func playlists(_ data: Data) throws -> Page<Playlist> {
        struct Owner: Decodable { let id: String }
        struct Count: Decodable { let total: Int }
        struct Entry: Decodable { let id: String; let name: String; let owner: Owner; let collaborative: Bool?; let items: Count?; let tracks: Count? }
        struct Response: Decodable { let items: [Entry?]; let next: URL? }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let lists = response.items.compactMap { $0 }.map {
            Playlist(id: $0.id, name: $0.name, ownerID: $0.owner.id, collaborative: $0.collaborative ?? false,
                     total: $0.items?.total ?? $0.tracks?.total ?? 0)
        }
        return Page(items: lists, next: response.next)
    }
}

/// lrclib.net: free synced lyrics, no API key.
public enum LRCLIB {
    public struct Record: Decodable, Sendable, Equatable {
        public let id: Int
        public let trackName: String?
        public let artistName: String?
        public let albumName: String?
        public let duration: Double?
        public let instrumental: Bool?
        public let syncedLyrics: String?
        public let plainLyrics: String?
    }

    /// Exact lookup; LRCLIB matches duration within about 2 s. A 404 means "no exact match".
    public static func getURL(for track: NowPlaying) -> URL {
        url("get", [("track_name", track.title), ("artist_name", track.artist),
                    ("album_name", track.album), ("duration", String(track.durationMs / 1000))])
    }

    /// Looser fallback; pick a result with `best(_:for:)`.
    public static func searchURL(for track: NowPlaying) -> URL {
        url("search", [("track_name", simplify(track.title)), ("artist_name", track.artist)])
    }

    /// The closest-duration result with synced lyrics whose title and artist match.
    public static func best(_ records: [Record], for track: NowPlaying) -> Record? {
        let title = key(simplify(track.title)), artist = key(track.artist)
        return records
            .filter { !($0.syncedLyrics ?? "").isEmpty }
            .filter { key(simplify($0.trackName ?? "")) == title }
            .filter { let other = key($0.artistName ?? ""); return other.contains(artist) || artist.contains(other) }
            .filter { abs(Int(($0.duration ?? 0) * 1000) - track.durationMs) <= 3000 }
            .min { abs(Int(($0.duration ?? 0) * 1000) - track.durationMs) < abs(Int(($1.duration ?? 0) * 1000) - track.durationMs) }
    }

    /// "Song - Remastered 2011" / "Song (feat. X)" → "Song". Spotify decorates titles; LRCLIB usually doesn't.
    public static func simplify(_ title: String) -> String {
        var value = title
        if let dash = value.range(of: " - ") { value = String(value[..<dash.lowerBound]) }
        value = value.replacing(/\s*[\(\[][^\)\]]*[\)\]]/, with: "")
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func key(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func url(_ path: String, _ query: [(String, String)]) -> URL {
        var parts = URLComponents(string: "https://lrclib.net/api/\(path)")!
        parts.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        return parts.url!
    }
}

/// Apple's free song search (no key), for the app's "check any song" box. It ranks by popularity, so an
/// artist's name lists their hits. LRCLIB's own search is a plain text match capped at 20 results, where
/// uploads titled "Artist - Song" bury the real songs.
public enum ITunesSearch {
    public static func url(_ term: String) -> URL {
        var parts = URLComponents(string: "https://itunes.apple.com/search")!
        parts.queryItems = [URLQueryItem(name: "term", value: term), URLQueryItem(name: "media", value: "music"),
                            URLQueryItem(name: "entity", value: "song"), URLQueryItem(name: "limit", value: "25")]
        return parts.url!
    }

    /// Songs as tracks LyricsLookup can check. The same song on several albums is kept once.
    public static func decode(_ data: Data) throws -> [NowPlaying] {
        struct Song: Decodable {
            let trackId: Int?
            let trackName: String?
            let artistName: String?
            let collectionName: String?
            let trackTimeMillis: Int?
        }
        struct Response: Decodable { let results: [Song] }
        var seen = Set<String>()
        return try JSONDecoder().decode(Response.self, from: data).results.compactMap { song in
            guard let id = song.trackId, let title = song.trackName, let artist = song.artistName,
                  let durationMs = song.trackTimeMillis,
                  seen.insert(title.lowercased() + "|" + artist.lowercased()).inserted else { return nil }
            return NowPlaying(trackID: "itunes:\(id)", title: title, artists: [artist], album: song.collectionName ?? "",
                              durationMs: durationMs,
                              playback: PlaybackSnapshot(progressMs: 0, sampledAt: .distantPast, isPlaying: false, durationMs: durationMs))
        }
    }
}
