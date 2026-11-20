import XCTest

/// Dedicated-device checks; prepare the seeded simulator before running these individually.
@MainActor final class DeviceChecks: XCTestCase {
    let app = XCUIApplication()

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }

    func testLargeTextListAndDetails() throws {
        let toggle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '标为完成，基准待办'")).firstMatch
        try XCTSkipUnless(toggle.exists, "需要基准模拟器")
        let mic = app.buttons["按住说话"]
        XCTAssertTrue(mic.isHittable)
        XCTAssertGreaterThanOrEqual(mic.frame.height, 44)
        XCTAssertGreaterThanOrEqual(toggle.frame.width, 44)
        XCTAssertGreaterThanOrEqual(toggle.frame.height, 44)
        let list = XCTAttachment(screenshot: app.screenshot())
        list.name = "最大字号清单"
        list.lifetime = .keepAlways
        add(list)
        let open = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '打开备注，基准待办'")).firstMatch
        open.tap()
        XCTAssertTrue(app.navigationBars["待办详情"].waitForExistence(timeout: 4))
        let dateButton = app.buttons["accessible.date.到期"]
        XCTAssertTrue(dateButton.exists, "此用例需要设置辅助功能字号")
        XCTAssertGreaterThanOrEqual(dateButton.frame.minX, 0)
        XCTAssertLessThanOrEqual(dateButton.frame.maxX, app.frame.maxX)
        let detail = XCTAttachment(screenshot: app.screenshot())
        detail.name = "最大字号详情"
        detail.lifetime = .keepAlways
        add(detail)
        dateButton.tap()
        XCTAssertTrue(app.navigationBars["到期"].waitForExistence(timeout: 3))
        app.navigationBars["到期"].buttons["完成"].tap()
        app.buttons["返回"].tap()
        XCTAssertTrue(mic.isHittable)
    }

    func testRefusedCalendarAndNotificationsPreserveTask() throws {
        let fixture = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '标为完成，基准待办'")).firstMatch
        try XCTSkipUnless(fixture.exists, "在尚未授权的专用基准模拟器运行")
        let name = "Denied " + String(UUID().uuidString.prefix(6))
        app.buttons["add"].tap()
        let title = app.descendants(matching: .any).matching(identifier: "editor.title").firstMatch
        title.tap()
        title.typeText(name)
        app.buttons["定时"].tap()
        app.buttons["editor.save"].tap()
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if alert.waitForExistence(timeout: 3) {
            alert.buttons.matching(NSPredicate(format: "label CONTAINS '不允许' OR label BEGINSWITH[c] 'Don'")).firstMatch.tap()
        }
        // A receipt is transient. The repair affordance must survive a fresh process.
        app.terminate()
        app.launch()
        let issue = app.buttons.matching(identifier: "row.reminderIssue")
            .matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", name, "不会提醒")).firstMatch
        for _ in 0..<8 {
            if issue.exists && issue.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(issue.exists && issue.isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "重启后仍显示提醒异常"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        issue.tap()
        XCTAssertTrue(app.buttons["前往通知设置"].waitForExistence(timeout: 4))
        app.buttons["reminder.cancel"].tap()
        let open = app.buttons["打开备注，" + name]
        XCTAssertTrue(open.waitForExistence(timeout: 4))
        open.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "通知未开启")).firstMatch.waitForExistence(timeout: 4))
        app.swipeUp()
        app.buttons["editor.calendar"].tap()
        if alert.waitForExistence(timeout: 4) {
            alert.buttons.matching(NSPredicate(format: "label CONTAINS '不允许' OR label BEGINSWITH[c] 'Don'")).firstMatch.tap()
        }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '日历未更新'")).firstMatch.waitForExistence(timeout: 4))
        app.buttons["取消"].tap()
        app.buttons["返回"].tap()
        app.buttons["标为完成，" + name].tap()
        app.buttons["撤销"].tap()
        XCTAssertTrue(open.exists)
        open.tap()
        app.swipeUp()
        app.buttons["删除待办"].tap()
        app.alerts.buttons["删除"].tap()
    }
}

extension DeviceChecks {
    func testChangedCustomClockCanBeCancelledAtLargeType() throws {
        let fixture = app.buttons["打开备注，基准待办 1"]
        try XCTSkipUnless(fixture.exists, "使用独立的基准模拟器和辅助功能字号")
        fixture.tap()
        let settings = app.buttons["editor.reminder"]
        func reveal(_ element: XCUIElement) {
            if element.exists && element.isHittable { return }
            // A sheet can still be animating out while its parent is in the AX tree.
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                element.exists && element.isHittable
            }, object: nil)
            if XCTWaiter.wait(for: [ready], timeout: 1.5) == .completed { return }
            app.swipeDown()
            app.swipeDown()
            for _ in 0..<7 {
                if element.exists && element.isHittable { return }
                app.swipeUp()
            }
            XCTAssertTrue(element.exists && element.isHittable)
        }
        reveal(settings)
        let customWasSaved = settings.label.contains("自选时间") || (settings.value as? String)?.contains("自选时间") == true
        settings.tap()
        let mode = app.buttons["reminder.mode"]
        let clock = app.buttons["accessible.date.提醒时间"]
        if !customWasSaved {
            reveal(mode)
            mode.tap()
            app.buttons["自选时间"].tap()
            reveal(clock)
            app.buttons["reminder.confirm"].tap()
            if app.alerts["提醒晚于到期时间"].waitForExistence(timeout: 2) {
                app.alerts.buttons["仍在这个时间提醒"].tap()
            }
            app.terminate()
            app.launch()
            fixture.tap()
            reveal(settings)
            settings.tap()
        }
        reveal(clock)
        let oldValue = clock.label
        clock.tap()
        let wheel = app.pickerWheels.firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 4))
        wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
        app.navigationBars["提醒时间"].buttons["完成"].tap()
        reveal(clock)
        XCTAssertNotEqual(clock.label, oldValue, "已在自选时间编辑器中改了日期")
        app.buttons["reminder.cancel"].tap()
        app.terminate()
        app.launch()
        fixture.tap()
        reveal(settings)
        settings.tap()
        reveal(clock)
        XCTAssertEqual(clock.label, oldValue, "取消并重启后保留原来的时刻")
        clock.tap()
        let nextDay = app.pickerWheels.firstMatch
        XCTAssertTrue(nextDay.waitForExistence(timeout: 4))
        nextDay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
        app.navigationBars["提醒时间"].buttons["完成"].tap()
        reveal(clock)
        let newValue = clock.label
        XCTAssertNotEqual(newValue, oldValue)
        app.buttons["reminder.confirm"].tap()
        let late = app.alerts["提醒晚于到期时间"]
        XCTAssertTrue(late.waitForExistence(timeout: 3))
        late.buttons["仍在这个时间提醒"].tap()
        app.terminate()
        app.launch()
        fixture.tap()
        reveal(settings)
        settings.tap()
        reveal(clock)
        XCTAssertEqual(clock.label, newValue, "明确确认后才替换")
        reveal(mode)
        mode.tap()
        app.buttons["仅保存"].tap()
        app.buttons["reminder.confirm"].tap()
    }
}
