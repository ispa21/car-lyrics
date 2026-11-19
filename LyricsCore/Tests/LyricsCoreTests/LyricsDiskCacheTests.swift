import Foundation
import Testing
@testable import LyricsCore

@Suite struct LyricsDiskCacheTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "LyricsDiskCacheTests-\(UUID().uuidString)")

    @Test func keepsLyricsAcrossInstances() {
        let entry = LyricsDiskCache.Entry(lrc: "[00:01.00]Hello\n[00:03.00]World", instrumental: false)
        LyricsDiskCache(folder: folder).save(entry, for: "6rqhFgbbKwnb9MLmUQDhG6")
        #expect(LyricsDiskCache(folder: folder).load("6rqhFgbbKwnb9MLmUQDhG6") == entry)  // a fresh instance, as after a relaunch
        #expect(LyricsDiskCache(folder: folder).load("unknown") == nil)
    }

    @Test func idsWithAnySymbolsMapToSafeDistinctFiles() {
        let cache = LyricsDiskCache(folder: folder)
        cache.save(.init(lrc: "a", instrumental: false), for: "am:1234")
        cache.save(.init(lrc: "b", instrumental: true), for: "am/1234")
        #expect(cache.load("am:1234")?.lrc == "a")
        #expect(cache.load("am/1234")?.instrumental == true)
        #expect(cache.file(for: "am:1234").deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
    }
}
