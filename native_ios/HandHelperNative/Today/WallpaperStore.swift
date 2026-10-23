import CryptoKit
import Foundation

@MainActor
final class WallpaperStore {
    private let session: any SessionStore
    private let directory: URL
    private let baseURL: URL

    init(session: any SessionStore, baseURL: URL = APIConfiguration.development.baseURL, directory: URL? = nil) {
        self.session = session
        self.baseURL = baseURL
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private var file: URL? {
        guard let cookie = session.cookie, !cookie.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data("\(baseURL.absoluteString)|\(cookie)".utf8))
        return directory.appendingPathComponent("today_wallpaper_\(digest.map { String(format: "%02x", $0) }.joined()).image")
    }

    func load() throws -> Data? {
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try Data(contentsOf: file)
    }

    func save(_ data: Data) throws {
        guard let file else { throw APIError.unauthorized(message: "请先登录后设置壁纸。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    func remove() throws {
        guard let file else { return }
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    nonisolated static func decodeDataURL(_ source: String?) -> Data? {
        guard let source, let comma = source.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: source[source.index(after: comma)...])
    }
}
