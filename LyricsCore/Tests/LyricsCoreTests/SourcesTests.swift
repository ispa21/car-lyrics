import Foundation
import Testing
@testable import LyricsCore

@Suite struct SpotifyDecoding {
    let t0 = Date(timeIntervalSince1970: 2_000)

    @Test func decodesPlayingTrack() throws {
        let json = #"""
        {"timestamp":1,"progress_ms":42000,"is_playing":true,"currently_playing_type":"track",
         "item":{"id":"abc","uri":"spotify:track:abc","name":"Song - Remastered 2011","duration_ms":200000,
                 "album":{"name":"Album"},"artists":[{"name":"Lead"},{"name":"Guest"}]}}
        """#
        let now = try #require(try SpotifyNowPlaying.decode(Data(json.utf8), sampledAt: t0))
        #expect(now.trackID == "abc" && now.artist == "Lead" && now.album == "Album")
        #expect(now.artworkURL == nil)  // no images in this response
        #expect(now.playback.position(at: t0.addingTimeInterval(1)) == 43_000)
    }

    @Test func picksTheSmallestAlbumArt() throws {
        let json = #"""
        {"progress_ms":1,"is_playing":true,"item":{"id":"a","name":"S","duration_ms":9,
         "album":{"name":"A","images":[{"url":"https://i.scdn.co/640","width":640},{"url":"https://i.scdn.co/64","width":64},{"url":"https://i.scdn.co/300","width":300}]}}}
        """#
        let now = try #require(try SpotifyNowPlaying.decode(Data(json.utf8), sampledAt: t0))
        #expect(now.artworkURL?.absoluteString == "https://i.scdn.co/64")
    }

    @Test func ignoresNothingAdsAndEpisodes() throws {
        #expect(try SpotifyNowPlaying.decode(Data(), sampledAt: t0) == nil)  // HTTP 204
        let ad = #"{"progress_ms":1000,"is_playing":true,"currently_playing_type":"ad","item":null}"#
        #expect(try SpotifyNowPlaying.decode(Data(ad.utf8), sampledAt: t0) == nil)
        let episode = #"{"progress_ms":1000,"is_playing":true,"currently_playing_type":"episode","item":{"id":"e","name":"Ep","duration_ms":9}}"#
        #expect(try SpotifyNowPlaying.decode(Data(episode.utf8), sampledAt: t0) == nil)
    }
}

@Suite struct LRCLIBMatching {
    let track = NowPlaying(trackID: "abc", title: "Song (feat. Guest) - Remastered", artists: ["Lead"], album: "Album",
                           durationMs: 200_000, playback: PlaybackSnapshot(progressMs: 0, sampledAt: .now, isPlaying: true))

    func record(_ id: Int, _ title: String, _ artist: String, _ seconds: Double, synced: Bool = true) -> LRCLIB.Record {
        .init(id: id, trackName: title, artistName: artist, albumName: nil, duration: seconds,
              instrumental: false, syncedLyrics: synced ? "[00:01.00]x" : nil, plainLyrics: "x")
    }

    @Test func simplifiesSpotifyTitles() {
        #expect(LRCLIB.simplify("Song (feat. Guest) - Remastered") == "Song")
        #expect(LRCLIB.simplify("Plain Title") == "Plain Title")
    }

    @Test func picksClosestSyncedMatch() {
        let picked = LRCLIB.best([
            record(1, "Song", "Lead", 205),                 // too far off (5 s)
            record(2, "Song", "Someone Else", 200),         // wrong artist
            record(3, "Song", "Lead", 200, synced: false),  // no synced lyrics
            record(4, "song", "Lead & Guest", 201.5),       // match
            record(5, "Song", "lead", 202.5),               // match, but further
        ], for: track)
        #expect(picked?.id == 4)
    }

    @Test func urlsCarryTheTrack() {
        let get = LRCLIB.getURL(for: track).absoluteString
        #expect(get.hasPrefix("https://lrclib.net/api/get?") && get.contains("duration=200") && get.contains("artist_name=Lead"))
        #expect(LRCLIB.searchURL(for: track).absoluteString.contains("track_name=Song&"))
    }
}

@Suite struct SpotifyQueueDecoding {
    @Test func decodesTracksAndSkipsEpisodes() throws {
        let json = #"""
        {"currently_playing":null,"queue":[
          {"id":"t1","type":"track","name":"First","duration_ms":180000,"album":{"name":"A"},"artists":[{"name":"X"}]},
          {"id":"e1","type":"episode","name":"Podcast","duration_ms":999},
          {"id":"t2","type":"track","name":"Second","duration_ms":200000,"album":{"name":"B"},"artists":[{"name":"Y"}]}]}
        """#
        let queue = try SpotifyQueue.decode(Data(json.utf8))
        #expect(queue.map(\.trackID) == ["t1", "t2"])
        #expect(queue[1].artist == "Y" && queue[1].durationMs == 200_000)
    }
}

@Suite struct ITunesSearchDecoding {
    @Test func decodesSongsAndDropsRepeats() throws {
        let json = #"""
        {"resultCount":4,"results":[
          {"trackId":1,"trackName":"Instant Crush","artistName":"Daft Punk & Julian Casablancas","collectionName":"Random Access Memories","trackTimeMillis":337560},
          {"trackId":2,"trackName":"Da Funk","artistName":"Daft Punk","collectionName":"Homework","trackTimeMillis":328000},
          {"trackId":3,"trackName":"Da Funk","artistName":"Daft Punk","collectionName":"Musique Vol. 1","trackTimeMillis":328000},
          {"trackId":4,"trackName":"No Length","artistName":"Daft Punk"}]}
        """#
        let songs = try ITunesSearch.decode(Data(json.utf8))
        #expect(songs.map(\.trackID) == ["itunes:1", "itunes:2"])
        #expect(songs[0].artist == "Daft Punk & Julian Casablancas" && songs[0].album == "Random Access Memories")
        #expect(songs[0].durationMs == 337_560)
        let url = ITunesSearch.url("daft punk").absoluteString
        #expect(url.hasPrefix("https://itunes.apple.com/search?term=daft%20punk") && url.contains("entity=song"))
    }
}

@Suite struct SpotifyLibraryDecoding {
    @Test func likedSongsUseTrack() throws {
        let json = #"""
        {"items":[{"added_at":"2026-01-01T00:00:00Z","track":{"id":"t1","type":"track","name":"One","duration_ms":200000,"album":{"name":"A"},"artists":[{"name":"X"}]}}],
         "next":"https://api.spotify.com/v1/me/tracks?offset=50&limit=50","total":51}
        """#
        let page = try SpotifyLibrary.tracks(Data(json.utf8))
        #expect(page.items.map(\.trackID) == ["t1"] && page.items[0].artist == "X" && page.items[0].durationMs == 200_000)
        #expect(page.next?.absoluteString == "https://api.spotify.com/v1/me/tracks?offset=50&limit=50")
    }

    @Test func playlistItemsUseItemAndSkipGaps() throws {
        let json = #"""
        {"items":[
          {"is_local":false,"item":{"id":"t2","type":"track","name":"Two","duration_ms":180000,"album":{"name":"B"},"artists":[{"name":"Y"}]},
                            "track":{"id":"t2","type":"track","name":"Two","duration_ms":180000,"album":{"name":"B"},"artists":[{"name":"Y"}]}},
          {"is_local":false,"item":null},
          {"is_local":false,"item":{"id":"e1","type":"episode","name":"Podcast","duration_ms":999}}],
         "next":null}
        """#
        let page = try SpotifyLibrary.tracks(Data(json.utf8))
        #expect(page.items.map(\.trackID) == ["t2"] && page.next == nil)
    }

    @Test func playlistsReadTheNewCountField() throws {
        let json = #"""
        {"items":[{"id":"p1","name":"Road trip","owner":{"id":"me"},"collaborative":false,"items":{"total":42}},
                  {"id":"p2","name":"Old shape","owner":{"id":"them"},"collaborative":true,"tracks":{"total":7}}],"next":null}
        """#
        let page = try SpotifyLibrary.playlists(Data(json.utf8))
        #expect(page.items.map(\.total) == [42, 7] && page.items[0].ownerID == "me" && page.items[1].collaborative)
    }
}
