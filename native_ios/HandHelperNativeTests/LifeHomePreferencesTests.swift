import XCTest
@testable import HandHelperNative

final class LifeHomePreferencesTests: XCTestCase {
    func testDefaultsPreserveExistingHomeAndPersistChanges() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var prefs = LifeHomePreferences(defaults: defaults)
        XCTAssertTrue(prefs.showWeather)
        XCTAssertTrue(prefs.showFinance)
        XCTAssertTrue(prefs.showShortcuts)
        XCTAssertTrue(prefs.showSubscriptions)
        XCTAssertFalse(prefs.hideFinancialAmounts)
        prefs.showWeather = false
        prefs.showFinance = false
        prefs.hideFinancialAmounts = true
        prefs.save(to: defaults)
        XCTAssertEqual(LifeHomePreferences(defaults: defaults), prefs)
    }

    func testAllModuleCombinationsKeepLedgerReachable() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        for mask in 0..<8 {
            var prefs = LifeHomePreferences(defaults: defaults)
            prefs.showFinance = mask & 1 != 0
            prefs.showShortcuts = mask & 2 != 0
            prefs.showSubscriptions = mask & 4 != 0
            XCTAssertEqual(prefs.hasVisibleModules, mask != 0)
            XCTAssertEqual(prefs.needsLedgerFallback, !prefs.showShortcuts)
            XCTAssertTrue(prefs.showShortcuts || prefs.needsLedgerFallback)
        }
    }

    func testFinancialMaskDoesNotMutateUnderlyingValue() {
        let original = "CNY 123.45"
        XCTAssertEqual(LifeDashboardCardText.display(original, concealed: true), "••••")
        XCTAssertEqual(original, "CNY 123.45")
        XCTAssertEqual(LifeDashboardCardText.display(original, concealed: false), original)
    }
}
