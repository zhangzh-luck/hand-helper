import Foundation

struct LedgerCategory: Codable, Identifiable, Equatable {
    let id: Int
    let name: String
    let kind: String
}

struct LedgerTransaction: Codable, Identifiable, Equatable {
    let id: Int
    let kind: String
    let amountMinor: Int64
    let currency: String
    let categoryID: Int?
    let occurredOn: String
    let note: String
    enum CodingKeys: String, CodingKey {
        case id, kind, currency, note
        case amountMinor = "amount_minor", categoryID = "category_id", occurredOn = "occurred_on"
    }
}

struct LedgerTransactionInput: Encodable {
    let kind: String
    let amountMinor: Int64
    let currency: String
    let categoryID: Int?
    let occurredOn: String
    let note: String
    enum CodingKeys: String, CodingKey {
        case kind, currency, note
        case amountMinor = "amount_minor", categoryID = "category_id", occurredOn = "occurred_on"
    }
}

struct LedgerCategoryInput: Encodable { let name: String; let kind: String }
struct LedgerBudgetInput: Encodable {
    let amountMinor: Int64
    let currency: String
    enum CodingKeys: String, CodingKey { case currency; case amountMinor = "amount_minor" }
}

struct LedgerDeleted: Decodable { let deleted: Bool }
struct LedgerBudget: Decodable {
    let amountMinor: Int64
    enum CodingKeys: String, CodingKey { case amountMinor = "amount_minor" }
}

struct LedgerSnapshot: Codable, Equatable {
    let summary: LifeSummary
    let transactions: [LedgerTransaction]
    let categories: [LedgerCategory]
    let savedAt: Date
}

enum LedgerAmount {
    static func precision(_ currency: String) -> Int? {
        switch currency {
        case "CNY", "USD", "EUR", "GBP", "HKD", "CAD", "AUD": return 2
        case "JPY", "KRW": return 0
        case "KWD", "BHD": return 3
        default: return nil
        }
    }

    static func parse(_ input: String, currency: String, allowZero: Bool = false) -> Int64? {
        guard let digits = precision(currency) else { return nil }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, !parts[0].isEmpty,
              parts.allSatisfy({ $0.allSatisfy { $0 >= "0" && $0 <= "9" } }),
              parts.count == 1 || (digits > 0 && !parts[1].isEmpty && parts[1].count <= digits),
              let whole = Int64(parts[0]) else { return nil }
        var multiplier: Int64 = 1
        for _ in 0..<digits { multiplier *= 10 }
        let fractional = parts.count == 2 ? String(parts[1]) : ""
        let padded = fractional + String(repeating: "0", count: digits - fractional.count)
        guard let fraction = Int64(padded.isEmpty ? "0" : padded) else { return nil }
        let (scaled, overflow1) = whole.multipliedReportingOverflow(by: multiplier)
        let (result, overflow2) = scaled.addingReportingOverflow(fraction)
        guard !overflow1, !overflow2, result <= 1_000_000_000_000,
              (allowZero ? result >= 0 : result > 0) else { return nil }
        return result
    }

    static func input(_ amount: Int64, currency: String) -> String {
        guard let digits = precision(currency) else { return "" }
        var multiplier: Int64 = 1
        for _ in 0..<digits { multiplier *= 10 }
        guard digits > 0 else { return String(amount) }
        return "\(amount / multiplier)." + String(format: "%0*lld", digits, amount % multiplier)
    }
}
