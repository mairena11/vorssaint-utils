// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

struct NotchMotionArtworkAlbum: Hashable {
    let storefront: String
    let catalogID: String

    var pageURL: URL {
        URL(string: "https://music.apple.com/\(storefront)/album/\(catalogID)")!
    }
}

struct NotchMotionArtworkAsset: Equatable {
    let videoURL: URL
    let previewURL: URL?
}

enum NotchMotionArtworkResolver {
    enum Failure: Error {
        case unavailable
    }

    private struct CatalogTrack {
        let track: String
        let artist: String
        let album: String
        let albumID: String
    }

    static func resolve(_ playback: NotchPlayback, storefrontHint: String? = nil) async throws
        -> (album: NotchMotionArtworkAlbum, asset: NotchMotionArtworkAsset) {
        guard playback.track.appBundleIdentifier == "com.apple.Music",
              let title = playback.track.title, !title.isEmpty,
              let artist = playback.track.artist, !artist.isEmpty,
              let albumName = playback.track.album, !albumName.isEmpty else { throw Failure.unavailable }

        let identifier = playback.itemIdentifier
        let storefront = storefront(from: identifier) ?? validStorefront(storefrontHint)
            ?? validStorefront(Locale.current.region?.identifier) ?? "us"
        let expectedAlbum = normalizedAlbum(albumName)
        let catalogTrack: CatalogTrack
        if let trackID = catalogTrackID(from: identifier),
           let result = try? await lookup(trackID: trackID, storefront: storefront),
           matches(result, title: title, artist: artist, album: expectedAlbum) {
            catalogTrack = result
        } else {
            catalogTrack = try await search(title: title, artist: artist, album: expectedAlbum,
                                            storefront: storefront)
        }
        let album = NotchMotionArtworkAlbum(storefront: storefront, catalogID: catalogTrack.albumID)
        let asset = try await motionAsset(for: album)
        return (album, asset)
    }

    static func storefront(from identifier: String?) -> String? {
        guard let identifier, let url = URLComponents(string: identifier)?.url,
              url.scheme == "https", url.host == "music.apple.com" else { return nil }
        return url.path.split(separator: "/").first.flatMap { validStorefront(String($0)) }
    }

    static func catalogTrackID(from identifier: String?) -> String? {
        guard let identifier else { return nil }
        if let components = URLComponents(string: identifier),
           components.scheme == "https", components.host == "music.apple.com",
           let id = components.queryItems?.first(where: { $0.name == "i" })?.value,
           isCatalogID(id) { return id }
        return isCatalogID(identifier) ? identifier : nil
    }

    static func normalizedAlbum(_ album: String) -> String {
        NotchLyricsSupport.catalogAlbum(album)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func catalogResultMatches(track: String, artist: String, album: String,
                                     title: String, expectedArtist: String, expectedAlbum: String) -> Bool {
        equal(track, title) && equal(artist, expectedArtist) && normalizedAlbum(album) == normalizedAlbum(expectedAlbum)
    }

    static func videoURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https",
              url.host == "mvod.itunes.apple.com" else { return nil }
        return url
    }

    private static func matches(_ track: CatalogTrack, title: String, artist: String, album: String) -> Bool {
        catalogResultMatches(track: track.track, artist: track.artist, album: track.album,
                             title: title, expectedArtist: artist, expectedAlbum: album)
    }

    private static func equal(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(rhs.trimmingCharacters(in: .whitespacesAndNewlines),
                     options: [.caseInsensitive, .diacriticInsensitive],
                     locale: Locale(identifier: "en_US_POSIX")) == .orderedSame
    }

    private static func validStorefront(_ value: String?) -> String? {
        guard let value, value.utf8.count == 2,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        return value.lowercased()
    }

    private static func isCatalogID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 20 && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func lookup(trackID: String, storefront: String) async throws -> CatalogTrack {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: trackID),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "country", value: storefront.uppercased())
        ]
        guard let url = components.url else { throw Failure.unavailable }
        let results = try await catalogResults(url)
        guard let result = results.first(where: { $0["wrapperType"] as? String == "track" }),
              let track = catalogTrack(result) else { throw Failure.unavailable }
        return track
    }

    private static func search(title: String, artist: String, album: String,
                               storefront: String) async throws -> CatalogTrack {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(title) \(artist) \(album)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "country", value: storefront.uppercased())
        ]
        guard let url = components.url else { throw Failure.unavailable }
        let results = try await catalogResults(url).compactMap(catalogTrack)
            .filter { matches($0, title: title, artist: artist, album: album) }
        let albums = Dictionary(grouping: results, by: \.albumID)
        guard albums.count == 1, let result = results.first else { throw Failure.unavailable }
        return result
    }

    private static func catalogTrack(_ value: [String: Any]) -> CatalogTrack? {
        guard let track = value["trackName"] as? String,
              let artist = value["artistName"] as? String,
              let album = value["collectionName"] as? String,
              let number = value["collectionId"] as? NSNumber else { return nil }
        let albumID = number.stringValue
        guard isCatalogID(albumID) else { return nil }
        return CatalogTrack(track: track, artist: artist, album: album, albumID: albumID)
    }

    private static func catalogResults(_ url: URL) async throws -> [[String: Any]] {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("Vorssaint/1.0 (Apple Music artwork lookup)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_000_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { throw Failure.unavailable }
        return results
    }

    private static func motionAsset(for album: NotchMotionArtworkAlbum) async throws -> NotchMotionArtworkAsset {
        var request = URLRequest(url: album.pageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 20_000_000,
              let html = String(data: data, encoding: .utf8),
              let start = html.range(of: "<script type=\"application/json\" id=\"serialized-server-data\">"),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex),
              let json = String(html[start.upperBound..<end.lowerBound]).data(using: .utf8) else {
            throw Failure.unavailable
        }
        return try parseMotionArtworkData(json, albumID: album.catalogID)
    }

    /// Only accept motion artwork from the specific album header we resolved.
    /// Apple pages may contain recommended albums with unrelated animations;
    /// searching recursively for any videoArtwork can display the wrong cover.
    static func parseMotionArtworkData(_ data: Data, albumID: String) throws -> NotchMotionArtworkAsset {
        guard data.count <= 20_000_000,
              isCatalogID(albumID),
              let artwork = matchingAlbumArtwork(try JSONSerialization.jsonObject(with: data), albumID: albumID),
              let rawVideo = artwork["video"] as? String,
              let videoURL = videoURL(rawVideo) else { throw Failure.unavailable }
        let previewRaw = (artwork["previewFrame"] as? [String: Any])?["url"] as? String
        return NotchMotionArtworkAsset(videoURL: videoURL, previewURL: previewRaw.flatMap(previewURL))
    }

    private static func matchingAlbumArtwork(_ object: Any, albumID: String) -> [String: Any]? {
        let pages: [[String: Any]]
        if let array = object as? [[String: Any]] { pages = array }
        else if let single = object as? [String: Any] { pages = [single] }
        else { return nil }

        for page in pages {
            guard let roots = page["data"] as? [[String: Any]] else { continue }
            for root in roots {
                guard let metadata = root["data"] as? [String: Any],
                      let sections = metadata["sections"] as? [[String: Any]] else { continue }
                for section in sections {
                    guard (section["id"] as? String)?.hasPrefix("album-detail-header") == true,
                          let items = section["items"] as? [[String: Any]] else { continue }
                    for item in items {
                        guard let descriptor = item["contentDescriptor"] as? [String: Any],
                              let ids = descriptor["identifiers"] as? [String: Any] else { continue }
                        let identified = ids["storeAdamID"] as? String
                            ?? (ids["storeAdamID"] as? NSNumber)?.stringValue
                        guard identified == albumID else { continue }
                        guard let videoArtwork = item["videoArtwork"] as? [String: Any],
                              let dictionary = videoArtwork["dictionary"] as? [String: Any],
                              let square = dictionary["motionDetailSquare"] as? [String: Any] else { return nil }
                        return square
                    }
                }
            }
        }
        return nil
    }

    private static func previewURL(_ raw: String) -> URL? {
        let expanded = raw.replacingOccurrences(of: "{w}", with: "320")
            .replacingOccurrences(of: "{h}", with: "320")
            .replacingOccurrences(of: "{f}", with: "jpg")
        guard let url = URL(string: expanded), url.scheme == "https",
              let host = url.host,
              (host == "mzstatic.com" || host.hasSuffix(".mzstatic.com")) else { return nil }
        return url
    }
}
