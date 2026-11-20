import XCTest

@MainActor
final class StoreListingTests: XCTestCase {
    /// Run on a fresh dedicated simulator. Uses only public flows and fictional examples.
    func testProductPageAndOfflinePrivacy() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func handlePermission() {
            let allow = system.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["允许", "Allow", "好", "OK"])).firstMatch
            if allow.waitForExistence(timeout: 1) { allow.tap() }
        }
        func add(_ name: String, notes: String = "") {
            app.buttons["add"].tap()
            let title = app.descendants(matching: .any).matching(identifier: "editor.title").firstMatch
            title.tap()
            title.typeText(name)
            if !notes.isEmpty {
                let field = app.descendants(matching: .any).matching(identifier: "editor.notes").firstMatch
                field.tap()
                field.typeText(notes)
            }
            app.buttons["editor.save"].tap()
            XCTAssertTrue(app.buttons["打开备注，" + name].waitForExistence(timeout: 4))
        }
        func enter(_ words: String) {
            app.buttons["按住说话"].tap()
            handlePermission()
            handlePermission()
            let field = app.descendants(matching: .any).matching(identifier: "capture.text").firstMatch
            if !field.waitForExistence(timeout: 2) { app.buttons["键入"].tap() }
            field.tap()
            field.typeText(words)
            app.buttons["完成"].tap()
            handlePermission()
        }
        func image(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            self.add(attachment)
        }
        app.buttons["privacy"].tap()
        XCTAssertTrue(app.navigationBars["隐私政策"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.webViews.staticTexts["待办与语音"].waitForExistence(timeout: 6))
        app.buttons["完成"].tap()
        add("买咖啡豆")
        add("整理周末的照片")
        enter("明天上午九点提醒我赶火车，备注提前到站，带上身份证")
        let train = app.buttons["打开备注，赶火车"]
        XCTAssertTrue(train.waitForExistence(timeout: 6))
        app.terminate()
        app.launch()
        XCTAssertTrue(train.waitForExistence(timeout: 4))
        image("01-list")
        train.tap()
        XCTAssertTrue(app.navigationBars["待办详情"].waitForExistence(timeout: 4))
        image("02-details")
        app.buttons["返回"].tap()
        enter("提醒我明天晚上聚会")
        XCTAssertTrue(app.staticTexts["明天晚上几点提醒？"].waitForExistence(timeout: 4))
        image("03-review")
    }
}
