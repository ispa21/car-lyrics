import AuthenticationServices
import CryptoKit
import Foundation
import LyricsCore
import Observation
import Security
import SwiftUI  // WebAuthenticationSession is the SwiftUI side of AuthenticationServices

enum SpotifyError: LocalizedError {
    case missingClientID, notConnected, login(String), rateLimited(Int), http(Int)

    var errorDescription: String? {
        switch self {
        case .missingClientID: "Add your Spotify Client ID to Local.xcconfig first (see README)"
        case .notConnected: "Not connected. Tap Connect Spotify."
        case .login(let reason): "Spotify login failed: \(reason)"
        case .rateLimited(let seconds): "Rate limited by Spotify; retrying in \(seconds) s"
        case .http(403): "Spotify refused (403). Is your account Premium, and added under User Management?"
        case .http(let status): "Spotify returned HTTP \(status)"
        }
    }
}

/// Spotify Web API with PKCE login (no client secret on the phone).
@MainActor @Observable
final class Spotify {
    /// developer.spotify.com/dashboard → your app → Settings → Client ID. Not a secret, but it's yours: put it in
    /// Local.xcconfig as SPOTIFY_CLIENT_ID (project.yml passes it to Info.plist).
    static let clientID = Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String ?? ""
    /// Must be added exactly like this under Redirect URIs in the same dashboard app.
    static let redirectURI = "lyricsdash://callback"
    /// The library ones let the Offline lyrics screen read Liked Songs and playlists. A login from before they were
    /// added lacks them until the user connects again (see `canReadLibrary`).
    private static let scopes = "user-read-currently-playing user-read-playback-state user-library-read playlist-read-private playlist-read-collaborative"

    private(set) var connected = Keychain.read("refresh_token") != nil
    /// What Spotify granted at the last login or token refresh.
    private(set) var grantedScopes = Set((Keychain.read("scope") ?? "").split(separator: " ").map(String.init))
    var canReadLibrary: Bool { grantedScopes.isSuperset(of: ["user-library-read", "playlist-read-private"]) }
    private var accessToken: String?
    private var expiry = Date.distantPast
    /// When the hour-long access token was last renewed, for the engine's status lines.
    private(set) var renewedAt: Date?

    func connect(with session: WebAuthenticationSession) async throws {
        guard !Self.clientID.isEmpty else { throw SpotifyError.missingClientID }
        let verifier = Self.randomString(64), state = Self.randomString(16)
        var authorize = URLComponents(string: "https://accounts.spotify.com/authorize")!
        authorize.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: Self.clientID),
            .init(name: "scope", value: Self.scopes),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: Data(SHA256.hash(data: Data(verifier.utf8))).base64URL),
            .init(name: "state", value: state),
        ]
        let callback = try await session.authenticate(using: authorize.url!, callback: .customScheme("lyricsdash"),
                                                      preferredBrowserSession: nil, additionalHeaderFields: [:])
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == state else { throw SpotifyError.login("state mismatch") }
        guard let code = value("code") else { throw SpotifyError.login(value("error") ?? "no code returned") }
        try await requestToken(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI,
                                "client_id": Self.clientID, "code_verifier": verifier])
    }

    func disconnect() {
        Keychain.delete("refresh_token")
        Keychain.delete("scope")
        grantedScopes = []
        accessToken = nil
        connected = false
    }

    /// nil when nothing (or an ad/podcast) is playing.
    func nowPlaying() async throws -> NowPlaying? {
        for attempt in 0..<2 {
            var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!, timeoutInterval: 10)
            request.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
            let started = Date.now
            let (data, response) = try await URLSession.shared.data(for: request)
            let midpoint = started.addingTimeInterval(Date.now.timeIntervalSince(started) / 2)
            let http = response as? HTTPURLResponse
            switch http?.statusCode ?? 0 {
            case 200: return try SpotifyNowPlaying.decode(data, sampledAt: midpoint)
            case 204: return nil
            case 401 where attempt == 0: accessToken = nil  // expired early: refresh once and retry
            case 429: throw SpotifyError.rateLimited(Int(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30)
            case let status: throw SpotifyError.http(status)
            }
        }
        throw SpotifyError.http(401)
    }

    /// The upcoming tracks in the user's Spotify queue (same scopes as now playing).
    func queue() async throws -> [NowPlaying] {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/queue")!, timeoutInterval: 10)
        request.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return try SpotifyQueue.decode(data)
    }

    /// Every song in Liked Songs.
    func likedSongs() async throws -> [NowPlaying] {
        try await all(from: URL(string: "https://api.spotify.com/v1/me/tracks?limit=50")!, SpotifyLibrary.tracks)
    }

    /// The playlists whose songs Spotify lets this app read: since February 2026, only ones the user made or
    /// collaborates on. Others answer 403, so they're left out.
    func playlists() async throws -> [SpotifyLibrary.Playlist] {
        struct Me: Decodable { let id: String }
        let me = try? JSONDecoder().decode(Me.self, from: try await get(URL(string: "https://api.spotify.com/v1/me")!))
        let lists = try await all(from: URL(string: "https://api.spotify.com/v1/me/playlists?limit=50")!, SpotifyLibrary.playlists)
        guard let me else { return lists }  // couldn't tell who the user is: list them all
        return lists.filter { $0.collaborative || $0.ownerID == me.id }
    }

    func playlistSongs(_ id: String) async throws -> [NowPlaying] {
        try await all(from: URL(string: "https://api.spotify.com/v1/playlists/\(id)/items?limit=50&additional_types=track")!, SpotifyLibrary.tracks)
    }

    /// Every page of a paged endpoint, waiting when Spotify asks to slow down (up to 30 s at a time).
    private func all<Item>(from url: URL, _ decode: (Data) throws -> SpotifyLibrary.Page<Item>) async throws -> [Item] {
        var items: [Item] = [], next: URL? = url
        while let page = next {
            do {
                let decoded = try decode(try await get(page))
                items += decoded.items
                next = decoded.next
            } catch SpotifyError.rateLimited(let seconds) {
                try await Task.sleep(for: .seconds(min(seconds, 30)))
            }
        }
        return items
    }

    /// A GET with the user's token, refreshing it once if Spotify says it expired.
    private func get(_ url: URL) async throws -> Data {
        for attempt in 0..<2 {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            switch http?.statusCode ?? 0 {
            case 200: return data
            case 401 where attempt == 0: accessToken = nil
            case 429: throw SpotifyError.rateLimited(Int(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30)
            case let status: throw SpotifyError.http(status)
            }
        }
        throw SpotifyError.http(401)
    }

    private func validToken() async throws -> String {
        if let accessToken, expiry > .now.addingTimeInterval(60) { return accessToken }
        guard let refresh = Keychain.read("refresh_token") else { connected = false; throw SpotifyError.notConnected }
        try await requestToken(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": Self.clientID])
        guard let accessToken else { throw SpotifyError.notConnected }
        return accessToken
    }

    private func requestToken(_ form: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = Data(form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }
            .joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 400 && form["grant_type"] == "refresh_token" { disconnect() }  // revoked: log in again
            throw SpotifyError.http(status)
        }
        struct Token: Decodable { let access_token: String; let expires_in: Int; let refresh_token: String?; let scope: String? }
        let token = try JSONDecoder().decode(Token.self, from: data)
        accessToken = token.access_token
        expiry = .now.addingTimeInterval(TimeInterval(token.expires_in))
        if form["grant_type"] == "refresh_token" { renewedAt = .now }
        if let refresh = token.refresh_token { Keychain.save(refresh, as: "refresh_token") }  // Spotify may rotate it
        if let scope = token.scope {
            Keychain.save(scope, as: "scope")
            grantedScopes = Set(scope.split(separator: " ").map(String.init))
        }
        connected = true
    }

    private static func randomString(_ length: Int) -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in characters.randomElement()! })  // SystemRandomNumberGenerator is a CSPRNG
    }
}

/// Refresh token storage. Readable after first unlock so polling works with the phone locked in the car.
enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "LyricsDash.spotify", kSecAttrAccount as String: account]
    }

    static func save(_ value: String, as account: String) {
        SecItemDelete(query(account) as CFDictionary)
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func read(_ account: String) -> String? {
        var item = query(account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
