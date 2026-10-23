import CryptoKit
import Foundation
import ImageIO

struct LocalProfile: Codable, Equatable {
    var displayName: String?
    var avatarData: Data?

    static let empty = LocalProfile(displayName: nil, avatarData: nil)
    var resolvedDisplayName: String { displayName ?? "航的助手" }
}

enum LocalProfileError: LocalizedError {
    case invalidName, invalidAvatar, invalidDocument

    var errorDescription: String? {
        switch self {
        case .invalidName: "显示名称需为 1 至 64 个字符。"
        case .invalidAvatar: "头像文件无效或超过 1 MB。"
        case .invalidDocument: "本机个人资料无法读取。"
        }
    }
}

@MainActor
final class LocalProfileStore {
    private struct Document: Codable {
        let version: Int
        let owner: String
        let profile: LocalProfile
    }

    private let session: any SessionStore
    private let account: VerifiedAccountContext
    private let baseURL: URL
    private let directory: URL

    init(session: any SessionStore, account: VerifiedAccountContext,
         baseURL: URL = APIConfiguration.development.baseURL, directory: URL? = nil) {
        self.session = session
        self.account = account
        self.baseURL = baseURL
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private func location() throws -> (owner: String, file: URL) {
        let owner = try account.requireOwner(cookie: session.cookie)
        let key = "\(baseURL.absoluteString)|\(owner)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return (owner, directory.appendingPathComponent("local_profile_v1_\(digest).json"))
    }

    func load() throws -> LocalProfile {
        let (owner, file) = try location()
        guard FileManager.default.fileExists(atPath: file.path) else { return .empty }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
        guard document.version == 1, document.owner == owner else { throw LocalProfileError.invalidDocument }
        return document.profile
    }

    @discardableResult
    func save(_ profile: LocalProfile) throws -> LocalProfile {
        let (owner, file) = try location()
        let name = profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, name.isEmpty || name.utf16.count > 64 { throw LocalProfileError.invalidName }
        if let avatar = profile.avatarData, avatar.isEmpty || avatar.count > 1_000_000 {
            throw LocalProfileError.invalidAvatar
        }
        if let avatar = profile.avatarData {
            guard let source = CGImageSourceCreateWithData(avatar as CFData, nil),
                  let type = CGImageSourceGetType(source),
                  CFEqual(type, "public.jpeg" as CFString),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                  let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
                  width == 512, height == 512 else { throw LocalProfileError.invalidAvatar }
        }
        let normalized = LocalProfile(displayName: name, avatarData: profile.avatarData)
        let data = try JSONEncoder().encode(Document(version: 1, owner: owner, profile: normalized))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return normalized
    }
}
