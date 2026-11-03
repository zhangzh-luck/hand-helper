import CryptoKit
import Foundation

// Device-only arrangements keyed by the verified account name. Legacy guest and
// temporary-session keys remain on disk but are never read or migrated.
@MainActor
final class LocalScheduleStore {
    private struct Account: Codable {
        var records: [CustomSchedule] = []
        var deletedRemoteIDs: Set<Int> = []
        var serverImported = false
    }
    private struct Document: Codable { var accounts: [String: Account] = [:] }

    private let session: any SessionStore
    private let account: VerifiedAccountContext
    private let directory: URL
    private let file: URL

    init(session: any SessionStore, account: VerifiedAccountContext,
         baseURL: URL = APIConfiguration.development.baseURL, directory: URL? = nil) {
        self.session = session
        self.account = account
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let baseHash = Self.digest(baseURL.absoluteString)
        file = self.directory.appendingPathComponent("local_schedules_\(baseHash).json")
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func owner() throws -> String { try account.requireOwner(cookie: session.cookie) }

    private func read() throws -> Document {
        guard FileManager.default.fileExists(atPath: file.path) else { return Document() }
        return try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
    }

    private func write(_ document: Document) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: file, options: .atomic)
    }

    func forDate(_ date: Date) throws -> [CustomSchedule] {
        let owner = try owner()
        let key = CourseScheduleCalculator.dateKey(date)
        return try (read().accounts[owner]?.records ?? [])
            .filter { $0.date == key }.sorted { ($0.time, $0.id) < ($1.time, $1.id) }
    }

    func all() throws -> [CustomSchedule] {
        let owner = try owner()
        return try read().accounts[owner]?.records ?? []
    }

    func save(_ schedule: CustomSchedule) throws {
        let key = try owner()
        var document = try read()
        var account = document.accounts[key] ?? Account()
        if schedule.id != 0 && !account.records.contains(where: { $0.id == schedule.id }) {
            throw TodayInputError.missingSchedule
        }
        let id = schedule.id == 0 ? (account.records.map(\.id).filter { $0 < 0 }.min() ?? 0) - 1 : schedule.id
        account.records.removeAll { $0.id == id }
        account.records.append(CustomSchedule(id: id, title: schedule.title, date: schedule.date,
                                              time: schedule.time, endTime: schedule.endTime))
        document.accounts[key] = account
        try write(document)
    }

    func delete(id: Int) throws {
        let key = try owner()
        var document = try read()
        var account = document.accounts[key] ?? Account()
        account.records.removeAll { $0.id == id }
        if id > 0 { account.deletedRemoteIDs.insert(id) }
        document.accounts[key] = account
        try write(document)
    }

    func importServerOnce(_ incoming: [CustomSchedule]) throws {
        let key = try owner()
        var document = try read()
        var account = document.accounts[key] ?? Account()
        guard !account.serverImported else { return }
        let known = Set(account.records.map(\.id))
        account.records += incoming.filter { !known.contains($0.id) && !account.deletedRemoteIDs.contains($0.id) }
        account.serverImported = true
        document.accounts[key] = account
        try write(document)
    }
}
