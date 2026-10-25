import Foundation
import XCTest
@testable import MacSWCore

final class AppPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var suite: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "MacSW-Preferences-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(suite)
    }

    override func tearDownWithError() throws {
        suite.removePersistentDomain(forName: suiteName)
    }

    /// 没写过这个键就等于没选过：打开 App 不能顺手把 SOLIDWORKS 拉起来。
    func testAutoLaunchDefaultsToOffSoOpeningTheAppStaysLightweight() {
        XCTAssertFalse(AppPreferences.autoLaunchSolidWorks(defaults: suite))
        suite.set(true, forKey: "MacSW.somethingElse")
        XCTAssertFalse(AppPreferences.autoLaunchSolidWorks(defaults: suite))
    }

    func testExplicitChoiceIsHonouredIncludingFalse() {
        let key = AppPreferences.autoLaunchSolidWorksKey
        suite.set(true, forKey: key)
        XCTAssertTrue(AppPreferences.autoLaunchSolidWorks(defaults: suite))
        suite.set(false, forKey: key)
        XCTAssertFalse(AppPreferences.autoLaunchSolidWorks(defaults: suite))
    }

    func testWineLocaleDefaultsToEnglishAndKeepsChineseSelectable() {
        XCTAssertEqual(AppPreferences.wineLocaleDefault, "en_US.UTF-8")
        XCTAssertEqual(AppPreferences.wineLocale(defaults: suite), "en_US.UTF-8")
        suite.set("zh_CN.UTF-8", forKey: AppPreferences.wineLocaleKey)
        XCTAssertEqual(AppPreferences.wineLocale(defaults: suite), "zh_CN.UTF-8")
        suite.set("en_US.UTF-8", forKey: AppPreferences.wineLocaleKey)
        XCTAssertEqual(AppPreferences.wineLocale(defaults: suite), "en_US.UTF-8")
    }

    /// The Mac file dialogs are on unless turned off explicitly, and an explicit choice either way
    /// is honoured (an explicit "off" from an earlier build stays off).
    func testMacFileDialogsDefaultOnAndExplicitChoiceIsHonoured() {
        XCTAssertTrue(AppPreferences.useMacFileDialogsDefault)
        XCTAssertTrue(AppPreferences.useMacFileDialogs(defaults: suite))
        suite.set(false, forKey: AppPreferences.useMacFileDialogsKey)
        XCTAssertFalse(AppPreferences.useMacFileDialogs(defaults: suite))
        suite.set(true, forKey: AppPreferences.useMacFileDialogsKey)
        XCTAssertTrue(AppPreferences.useMacFileDialogs(defaults: suite))
    }

    /// Drive letters for the Mac folders are on unless turned off in Settings.
    func testMapMacFoldersDefaultsOnAndCanBeTurnedOff() {
        XCTAssertTrue(AppPreferences.mapMacFoldersDefault)
        XCTAssertTrue(AppPreferences.mapMacFolders(defaults: suite))
        suite.set(false, forKey: AppPreferences.mapMacFoldersKey)
        XCTAssertFalse(AppPreferences.mapMacFolders(defaults: suite))
        suite.set(true, forKey: AppPreferences.mapMacFoldersKey)
        XCTAssertTrue(AppPreferences.mapMacFolders(defaults: suite))
    }

    /// The hidden "everywhere" switch is on (File > Open included) unless turned off explicitly.
    func testMacFileDialogsEverywhereIsOnByDefault() {
        XCTAssertTrue(AppPreferences.macFileDialogsEverywhereDefault)
        XCTAssertTrue(AppPreferences.macFileDialogsEverywhere(defaults: suite))
        suite.set(false, forKey: AppPreferences.macFileDialogsEverywhereKey)
        XCTAssertFalse(AppPreferences.macFileDialogsEverywhere(defaults: suite))
        suite.set(true, forKey: AppPreferences.macFileDialogsEverywhereKey)
        XCTAssertTrue(AppPreferences.macFileDialogsEverywhere(defaults: suite))
    }

    func testUnsupportedWineLocaleFallsBackToDefault() {
        suite.set("ja_JP.UTF-8; rm -rf /", forKey: AppPreferences.wineLocaleKey)
        XCTAssertEqual(AppPreferences.wineLocale(defaults: suite), AppPreferences.wineLocaleDefault)
    }
}
