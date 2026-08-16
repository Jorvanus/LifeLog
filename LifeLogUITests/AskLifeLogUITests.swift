import XCTest

/// The seeded end-to-end path: Insights → Ask LifeLog → a real answer from
/// `FakeAskLifeLogPlanner.uiTestPlanner()` (never live Apple Intelligence) →
/// drill down into the resolved place → back to Insights with the period and
/// scope exactly as they were left.
final class AskLifeLogUITests: LifeLogUITestCase {
    func testAskLifeLogAnswersAndDrillDownPreservesPeriodAndScope() {
        launchSeededInsights(extraArguments: ["-ui-test-ask-lifelog-fake"])

        // Move off the default Day/All-history selection so a preserved period
        // and scope after the round trip is actually asserting something.
        app.buttons["Week"].tap()
        XCTAssertTrue(element("insights-weekly-strip").waitForExistence(timeout: 10))
        XCTAssertTrue(element("insights-scope-picker").waitForExistence(timeout: 5))
        element("insights-scope-picker").tap()
        XCTAssertTrue(app.buttons["Device + manual only"].waitForExistence(timeout: 5))
        app.buttons["Device + manual only"].tap()

        XCTAssertTrue(element("insights-ask-lifelog-button").waitForExistence(timeout: 5))
        element("insights-ask-lifelog-button").tap()

        XCTAssertTrue(element("ask-lifelog-sheet").waitForExistence(timeout: 5))
        let questionField = element("ask-lifelog-question-field")
        XCTAssertTrue(questionField.waitForExistence(timeout: 5))
        questionField.tap()
        questionField.typeText("How much time did I spend at Home this week?")
        element("ask-lifelog-submit").tap()

        XCTAssertTrue(element("ask-lifelog-answer").waitForExistence(timeout: 10))
        XCTAssertTrue(element("ask-lifelog-drill-down").waitForExistence(timeout: 5))
        element("ask-lifelog-drill-down").tap()

        // The sheet dismisses and the answer's drill-down pushes onto Insights'
        // own navigation stack, landing on the resolved place's history.
        XCTAssertFalse(element("ask-lifelog-sheet").exists)
        XCTAssertTrue(element("insight-place-history-detail").waitForExistence(timeout: 10))

        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Back on Insights: still Week, still Device + manual only.
        XCTAssertTrue(element("insights-weekly-strip").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Device + manual only"].waitForExistence(timeout: 5))
    }

    func testAskLifeLogUnsupportedQuestionIsRejectedClearly() {
        launchSeededInsights(extraArguments: ["-ui-test-ask-lifelog-fake"])

        element("insights-ask-lifelog-button").tap()
        let questionField = element("ask-lifelog-question-field")
        XCTAssertTrue(questionField.waitForExistence(timeout: 5))
        questionField.tap()
        questionField.typeText("What's my favourite pizza topping?")
        element("ask-lifelog-submit").tap()

        XCTAssertTrue(element("ask-lifelog-message").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["I can't answer that yet"].waitForExistence(timeout: 5))
    }
}
