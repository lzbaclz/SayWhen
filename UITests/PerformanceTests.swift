import XCTest

@MainActor final class PerformanceTests: XCTestCase {
    func testCompletionFeedbackOnSeededSimulator() throws {
        let app = XCUIApplication()
        app.launch()
        let first = app.buttons["标为完成，基准待办 1"]
        try XCTSkipUnless(first.exists, "此性能用例需要独立的 1,000 条测试数据库")
        for _ in 0..<50 {
            first.tap()
            let undo = app.buttons["撤销"]
            XCTAssertTrue(undo.exists)
            undo.tap()
            XCTAssertTrue(first.exists)
        }
    }

    func testReleaseColdLaunchOnSeededSimulator() throws {
        let app = XCUIApplication()
        app.launch()
        let first = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '标为完成，基准待办'")).firstMatch
        try XCTSkipUnless(first.exists, "此性能用例需要独立的 1,000 条测试数据库")
        XCTAssertTrue(first.isHittable)
        XCTAssertTrue(app.buttons["按住说话"].isHittable)
        app.terminate()
        let options = XCTMeasureOptions()
        options.iterationCount = 50
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            app.launch()
            XCTAssertTrue(first.isHittable)
            XCTAssertTrue(app.buttons["按住说话"].isHittable)
        }
    }
}
