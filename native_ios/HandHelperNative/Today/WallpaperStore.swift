import CryptoKit
import Foundation

enum WallpaperKind: Hashable {
    case today
    case timetable
    case analysis
}

@MainActor
final class WallpaperStore {
    private let session: any SessionStore
    private let account: VerifiedAccountContext
    private let directory: URL
    private let baseURL: URL
    let kind: WallpaperKind

    init(session: any SessionStore, account: VerifiedAccountContext,
         kind: WallpaperKind = .today,
         baseURL: URL = APIConfiguration.development.baseURL, directory: URL? = nil) {
        self.session = session
        self.account = account
        self.kind = kind
        self.baseURL = baseURL
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private var deviceFile: URL {
        let name: String
        switch kind {
        case .today: name = "today_wallpaper_device_v1.image"
        case .timetable: name = "timetable_wallpaper_device_v1.image"
        case .analysis: name = "analysis_wallpaper_device_v1.image"
        }
        return directory.appendingPathComponent(name)
    }

    private var legacyFile: URL? {
        guard kind == .today else { return nil }
        guard let cookie = session.cookie, !cookie.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data("\(baseURL.absoluteString)|\(cookie)".utf8))
        return directory.appendingPathComponent("today_wallpaper_\(digest.map { String(format: "%02x", $0) }.joined()).image")
    }

    func load() throws -> Data? {
        _ = try account.requireOwner(cookie: session.cookie)
        if FileManager.default.fileExists(atPath: deviceFile.path) {
            let data = try Data(contentsOf: deviceFile)
            return data.isEmpty ? nil : data
        }
        // Only the current verified Cookie can identify a legacy file. An
        // existing device file, including an empty default marker, always wins.
        guard let legacyFile, FileManager.default.fileExists(atPath: legacyFile.path) else { return nil }
        let data = try Data(contentsOf: legacyFile)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: deviceFile, options: .atomic)
        return data.isEmpty ? nil : data
    }

    func save(_ data: Data) throws {
        _ = try account.requireOwner(cookie: session.cookie)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: deviceFile, options: .atomic)
    }

    func remove() throws {
        _ = try account.requireOwner(cookie: session.cookie)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Empty data records the explicit default background so an old
        // Cookie-scoped image cannot be imported again after restoration.
        try Data().write(to: deviceFile, options: .atomic)
    }

    nonisolated static func decodeDataURL(_ source: String?) -> Data? {
        guard let source, let comma = source.firstIndex(of: ",") else { return nil }
        let start = source.index(after: comma)
        let encoded = String(source[start...])
        return Data(base64Encoded: encoded)
    }
}
