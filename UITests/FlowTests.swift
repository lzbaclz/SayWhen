import XCTest

@MainActor final class FlowTests: XCTestCase {
    let app = XCUIApplication()

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }

    private func allowIfPresented(seconds: TimeInterval = 4) {
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = system.alerts.firstMatch
        guard alert.waitForExistence(timeout: seconds) else { return }
        let allow = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Allow","允许","Allow Full Access","允许完全访问","允许完全访问权限"])).firstMatch
        if allow.exists { allow.tap() }
    }

    func testManualOfflineWorkflowAndPersistence() {
        let name = "Notes " + String(UUID().uuidString.prefix(6))
        app.buttons["add"].tap()
        let title = app.descendants(matching: .any).matching(identifier: "editor.title").firstMatch
        title.tap()
        title.typeText(name)
        let notes = app.descendants(matching: .any).matching(identifier: "editor.notes").firstMatch
        notes.tap()
        notes.typeText("First line\nSecond line")
        app.buttons["editor.save"].tap()
        let open = app.buttons["打开备注，" + name]
        XCTAssertTrue(open.waitForExistence(timeout: 4))
        app.buttons["标为完成，" + name].tap()
        app.terminate()
        app.launch()
        XCTAssertFalse(open.exists)
        app.buttons["history"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 3))
        open.tap()
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "editor.notes").firstMatch.value as? String, "First line\nSecond line")
        app.buttons["返回"].tap()
        app.buttons["恢复，" + name].tap()
        app.buttons["撤销"].tap()
        XCTAssertTrue(app.buttons["恢复，" + name].exists)
        app.buttons["恢复，" + name].tap()
        open.tap()
        let editor = app.descendants(matching: .any).matching(identifier: "editor.notes").firstMatch
        editor.tap()
        editor.typeText(" saved")
        let editedText = editor.value as? String
        XCTAssertTrue(editedText?.contains(" saved") == true)
        app.buttons["返回"].tap()
        open.tap()
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "editor.notes").firstMatch.value as? String, editedText)
        app.buttons["editor.calendar"].tap()
        XCTAssertTrue(app.navigationBars["补选日期"].waitForExistence(timeout: 4))
        app.buttons["取消"].tap()
        app.buttons["删除待办"].tap()
        app.alerts.buttons["删除"].tap()
        XCTAssertFalse(open.exists)
    }

    func testSystemPermissionsAndManualCalendarSync() {
        let name = "Calendar " + String(UUID().uuidString.prefix(6))
        app.buttons["add"].tap()
        let title = app.descendants(matching: .any).matching(identifier: "editor.title").firstMatch
        title.tap()
        title.typeText(name)
        app.buttons["定时"].tap()
        app.buttons["editor.save"].tap()
        allowIfPresented()
        let open = app.buttons["打开备注，" + name]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        app.swipeUp()
        app.buttons["editor.calendar"].tap()
        allowIfPresented()
        let confirm = app.buttons["确认同步"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.tap()
        XCTAssertTrue(app.buttons["核对日历"].waitForExistence(timeout: 5) || app.buttons["editor.calendar"].label == "核对日历")
        app.buttons["删除待办"].tap()
        app.alerts.buttons["删除"].tap()
    }

    func testReviewTwoDictatedItemsFromKeyboard() {
        app.buttons["按住说话"].tap()
        allowIfPresented(seconds: 1)
        allowIfPresented(seconds: 1)
        let field = app.descendants(matching: .any).matching(identifier: "capture.text").firstMatch
        if !field.waitForExistence(timeout: 2) { app.buttons["键入"].tap() }
        field.tap()
        field.typeText("明天寄快递，后天去复诊，备注带上医保卡")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["核对待办"].waitForExistence(timeout: 4))
        app.buttons["保存"].tap()
        XCTAssertTrue(app.buttons["打开备注，寄快递"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["打开备注，去复诊"].exists)
        app.buttons["撤销"].tap()
        XCTAssertFalse(app.buttons["打开备注，寄快递"].exists)
        XCTAssertFalse(app.buttons["打开备注，去复诊"].exists)
    }

    func testMicrophoneEntryOffersRecordingOrKeyboard() {
        app.buttons["按住说话"].tap()
        allowIfPresented(seconds: 1)
        allowIfPresented(seconds: 1)
        let field = app.descendants(matching: .any).matching(identifier: "capture.text").firstMatch
        if field.waitForExistence(timeout: 3) {
            let name = "Coffee " + String(UUID().uuidString.prefix(6))
            field.tap()
            field.typeText(name)
            app.buttons["完成"].tap()
            XCTAssertTrue(app.buttons["打开备注，" + name].waitForExistence(timeout: 3))
            app.buttons["撤销"].tap()
            XCTAssertFalse(app.buttons["打开备注，" + name].exists)
        } else {
            XCTAssertTrue(app.buttons["完成录入"].exists)
            app.buttons["取消"].tap()
        }
    }
}


extension FlowTests {
    func testNotificationOpensTaskAfterProcessExit() {
        app.buttons["按住说话"].tap()
        allowIfPresented(seconds: 1)
        allowIfPresented(seconds: 1)
        let field = app.descendants(matching: .any).matching(identifier: "capture.text").firstMatch
        if !field.waitForExistence(timeout: 2) { app.buttons["键入"].tap() }
        let cal = Calendar.current
        let due = cal.dateInterval(of: .minute, for: Date().addingTimeInterval(90))!.start
        let day = cal.isDateInToday(due) ? "今天" : "明天"
        let clock = String(format: "%02d:%02d", cal.component(.hour, from: due), cal.component(.minute, from: due))
        let name = "回到待办" + String(Int.random(in: 100000...999999))
        field.tap()
        field.typeText(day + clock + name)
        app.buttons["完成"].tap()
        allowIfPresented(seconds: 1)
        XCTAssertTrue(app.buttons["打开备注，" + name].waitForExistence(timeout: 4))
        app.terminate()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = system.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: max(10, due.timeIntervalSinceNow + 12)), system.debugDescription)
        banner.tap()
        XCTAssertTrue(app.navigationBars["待办详情"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "editor.title").firstMatch.value as? String, name)
        app.swipeUp()
        app.buttons["删除待办"].tap()
        app.alerts.buttons["删除"].tap()
    }
}

extension FlowTests {
    private func enterUtterance(_ text: String) {
        app.buttons["按住说话"].tap()
        allowIfPresented(seconds: 1)
        allowIfPresented(seconds: 1)
        let field = app.descendants(matching: .any).matching(identifier: "capture.text").firstMatch
        if !field.waitForExistence(timeout: 2) { app.buttons["键入"].tap() }
        field.tap()
        field.typeText(text)
        app.buttons["完成"].tap()
    }

    func testReceiptOffersImmediateCorrectionAndUndo() throws {
        let marker = String(Int.random(in: 10000...99999))
        let title = "交油" + marker
        enterUtterance("下周一早上九点提醒我" + title + "，备注带上水")
        let receipt = app.buttons["receipt.editTitle"]
        XCTAssertTrue(receipt.waitForExistence(timeout: 6))
        XCTAssertTrue(receipt.label.contains(title), receipt.label)
        XCTAssertTrue(receipt.label.contains("09:00"), receipt.label)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "保存回执与改字入口"
        image.lifetime = .keepAlways
        add(image)
        receipt.tap()
        let field = app.descendants(matching: .any).matching(identifier: "rename.title").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        // Typing directly after opening is the user-facing focus contract.
        field.typeText("改")
        let newTitle = try XCTUnwrap(field.value as? String)
        XCTAssertTrue(newTitle.contains("改"))
        app.buttons["rename.save"].tap()
        XCTAssertTrue(receipt.waitForExistence(timeout: 3))
        XCTAssertTrue(receipt.label.contains(newTitle))
        XCTAssertTrue(app.buttons["打开备注，" + newTitle].exists)
        app.buttons["撤销"].tap()
        XCTAssertFalse(app.buttons["打开备注，" + newTitle].exists)
    }

    func testKnownDayAsksOnlyForTimeAndSupportsAllDay() {
        let name = "聚会" + String(Int.random(in: 10000...99999))
        enterUtterance("提醒我明天晚上" + name)
        let save = app.navigationBars["核对待办"].buttons["保存"]
        XCTAssertTrue(app.staticTexts["明天晚上几点提醒？"].waitForExistence(timeout: 4))
        XCTAssertFalse(save.isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "已知日期只补钟点"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["review.chooseClock"].tap()
        app.navigationBars["明天晚上"].buttons["取消"].tap()
        XCTAssertFalse(save.isEnabled)
        app.buttons["review.chooseClock"].tap()
        app.buttons["review.confirmClock"].tap()
        save.tap()
        let receipt = app.buttons["receipt.editTitle"]
        XCTAssertTrue(receipt.waitForExistence(timeout: 4))
        XCTAssertTrue(receipt.label.contains("明天") && receipt.label.contains("20:00"), receipt.label)
        XCTAssertTrue(app.buttons["打开备注，" + name].exists)
        app.buttons["撤销"].tap()

        enterUtterance("后天下午" + name)
        app.buttons["review.keepDay"].tap()
        save.tap()
        XCTAssertTrue(receipt.waitForExistence(timeout: 3))
        XCTAssertTrue(receipt.label.contains("后天") && receipt.label.contains("全天"), receipt.label)
        XCTAssertTrue(app.buttons["打开备注，" + name].exists)
        app.buttons["撤销"].tap()
    }

    func testCancelCustomReminderKeepsRuleAcrossRelaunch() {
        let name = "交房租" + String(Int.random(in: 10000...99999))
        enterUtterance("下周一早上九点提醒我" + name)
        let open = app.buttons["打开备注，" + name]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        let reminder = app.buttons["editor.reminder"]
        XCTAssertTrue(reminder.waitForExistence(timeout: 3))
        let firstLabel = reminder.label
        reminder.tap()
        let mode = app.buttons["reminder.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 3))
        let originalClock = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "将提醒于", "09:00")).firstMatch
        XCTAssertTrue(originalClock.exists, app.debugDescription)
        mode.tap()
        app.buttons["自选时间"].tap()
        XCTAssertTrue(originalClock.exists)
        app.buttons["reminder.cancel"].tap()
        XCTAssertEqual(reminder.label, firstLabel)
        app.terminate()
        app.launch()
        open.tap()
        XCTAssertTrue(reminder.label.contains("到点提醒") || (reminder.value as? String)?.contains("到点提醒") == true,
                      app.debugDescription)
        reminder.tap()
        XCTAssertTrue(originalClock.exists)
        mode.tap()
        XCTAssertTrue(app.buttons["到点提醒"].exists)
        app.buttons["提前一天"].tap()
        app.buttons["reminder.confirm"].tap()
        XCTAssertTrue(reminder.waitForExistence(timeout: 3))
        XCTAssertTrue(reminder.label.contains("提前一天") || (reminder.value as? String)?.contains("提前一天") == true,
                      app.debugDescription)
        app.swipeUp()
        app.buttons["删除待办"].tap()
        app.alerts.buttons["删除"].tap()
    }
}

extension FlowTests {
    func testGlobalLeadAndIndividualOverrideFromNormalEntry() {
        let name = "发送报告" + String(Int.random(in: 10000...99999))
        let settings = app.buttons["settings"]
        let globalMode = app.buttons["settings.default"]
        settings.tap()
        globalMode.tap()
        app.buttons["提前 2 小时"].tap()
        app.buttons["settings.save"].tap()
        app.terminate()
        app.launch()
        settings.tap()
        XCTAssertTrue(globalMode.label.contains("提前 2 小时") || (globalMode.value as? String)?.contains("提前 2 小时") == true)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "全局默认提醒"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.navigationBars["设置"].buttons["取消"].tap()

        enterUtterance("大后天早晨十点" + name)
        let receipt = app.buttons["receipt.editTitle"]
        XCTAssertTrue(receipt.waitForExistence(timeout: 5))
        XCTAssertTrue(receipt.label.contains("08:00"), receipt.label)
        let open = app.buttons["打开备注，" + name]
        open.tap()
        app.buttons["editor.reminder"].tap()
        let mode = app.buttons["reminder.mode"]
        mode.tap()
        app.buttons["提前 15 分钟"].tap()
        let expected = app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@ AND label CONTAINS %@", "提醒", "09:45")).firstMatch
        XCTAssertTrue(expected.exists, app.debugDescription)
        app.buttons["reminder.confirm"].tap()
        app.buttons["返回"].tap()
        settings.tap()
        globalMode.tap()
        app.buttons["自定义提前量"].tap()
        let amount = app.textFields["advance.amount"]
        XCTAssertTrue(amount.exists)
        amount.tap()
        amount.typeText(XCUIKeyboardKey.delete.rawValue + "3")
        app.buttons["settings.save"].tap()
        settings.tap()
        XCTAssertEqual(amount.value as? String, "3")
        app.navigationBars["设置"].buttons["取消"].tap()
        enterUtterance("大后天早晨十点核对账单" + String(Int.random(in: 1000...9999)))
        XCTAssertTrue(receipt.waitForExistence(timeout: 5))
        XCTAssertTrue(receipt.label.contains("07:00"), receipt.label)
        app.buttons["撤销"].tap()
        settings.tap()
        globalMode.tap()
        app.buttons["前一天晚上 20:00"].tap()
        app.buttons["settings.save"].tap()
        open.tap()
        app.buttons["editor.reminder"].tap()
        XCTAssertTrue(expected.exists)
        let override = XCTAttachment(screenshot: app.screenshot())
        override.name = "单条提前十五分钟"; override.lifetime = .keepAlways; add(override)
        mode.tap()
        app.buttons["跟随全局 · 前一天晚上 20:00"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@ AND label CONTAINS %@", "提醒", "20:00")).firstMatch.exists)
        app.buttons["reminder.confirm"].tap()
        app.swipeUp()
        app.buttons["删除待办"].tap()
        app.alerts.buttons["删除"].tap()
    }

    func testSpokenActionTitleAndPreviouslySavedTitle() {
        let suffix = String(Int.random(in: 1000...9999))
        let name = "告诉同事 CVPR 邮件" + suffix
        enterUtterance("明天早晨十点提醒我，我告诉同事CVPR邮件" + suffix)
        let open = app.buttons["打开备注，" + name]
        XCTAssertTrue(open.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["receipt.editTitle"].label.contains("10:00"))
        app.buttons["撤销"].tap()

        let old = "早晨提醒我，我告诉同事CVPR邮件" + suffix
        app.buttons["add"].tap()
        let title = app.descendants(matching:.any).matching(identifier:"editor.title").firstMatch
        title.tap()
        title.typeText(old)
        app.buttons["editor.save"].tap()
        app.buttons["打开备注，" + old].tap()
        app.buttons["editor.cleanTitle"].tap()
        XCTAssertEqual(title.value as? String, name)
        app.buttons["返回"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 3))
        open.tap()
        app.buttons["删除待办"].tap()
        app.alerts.buttons["删除"].tap()
    }
}
