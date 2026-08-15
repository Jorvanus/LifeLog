import XCTest

/// Insights at Week/Month/Year granularity: each period's hero cards,
/// calendars, place/health pickers, and selection state.
final class InsightsPeriodTests: LifeLogUITestCase {
    func testWeekInsightsKeepsStripHeroAndCombinesWeeklyBalance() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed", "-ui-test-week-travel"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()

        XCTAssertTrue(app.buttons["Week"].waitForExistence(timeout: 5))
        app.buttons["Week"].tap()
        XCTAssertTrue(element("insights-weekly-strip").waitForExistence(timeout: 10))
        XCTAssertTrue(element("insights-week-your-week").waitForExistence(timeout: 10))
        XCTAssertTrue(element("insights-getting-around").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Each column is a day; colours show where your time went."].exists)
        XCTAssertFalse(element("insights-week-scorecard").exists)
        XCTAssertFalse(element("insights-week-groups").exists)
        XCTAssertFalse(element("insights-week-commute").exists)

        let selectedDay = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'selected'"))
            .firstMatch
        XCTAssertTrue(selectedDay.waitForExistence(timeout: 5))
        let weekColumns = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'logged'"))
        XCTAssertTrue(weekColumns.firstMatch.exists)
        weekColumns.firstMatch.tap()
        XCTAssertTrue(element("weekly-selected-day").waitForExistence(timeout: 5))
        weekColumns.firstMatch.tap()
        XCTAssertFalse(element("weekly-selected-day").exists)
    }

    func testMonthInsightsUsesOneHeroCardForHeadlineAndKeyMetrics() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()

        XCTAssertTrue(app.buttons["Month"].waitForExistence(timeout: 5))
        app.buttons["Month"].tap()
        XCTAssertTrue(element("insights-month-hero").waitForExistence(timeout: 10))
        XCTAssertFalse(element("insights-month-headline").exists)
        XCTAssertFalse(element("insights-month-scorecard").exists)
        XCTAssertFalse(element("insights-travel-summary").exists)
    }

    func testMonthInsightsCalendarHasWeekdaysAndLegend() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()

        XCTAssertTrue(app.buttons["Month"].waitForExistence(timeout: 5))
        app.buttons["Month"].tap()
        XCTAssertTrue(element("insights-month-calendar").waitForExistence(timeout: 10))
        XCTAssertTrue(element("month-calendar-weekdays").waitForExistence(timeout: 5))
        XCTAssertTrue(element("month-calendar-legend").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No data"].exists)
        XCTAssertTrue(app.staticTexts["Mostly Home"].exists)
        XCTAssertTrue(app.staticTexts["Activity"].exists)
        XCTAssertTrue(app.staticTexts["Away from Home"].exists)
    }

    func testMonthPlaceStoryUsesFocusedSections() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()

        XCTAssertTrue(app.buttons["Month"].waitForExistence(timeout: 5))
        app.buttons["Month"].tap()
        XCTAssertTrue(element("insights-month-places").waitForExistence(timeout: 10))
        XCTAssertTrue(element("month-place-story-picker").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Most time"].exists)
        XCTAssertTrue(app.buttons["Most visits"].exists)
        XCTAssertTrue(app.buttons["New"].exists)
        XCTAssertTrue(app.buttons["Changed"].exists)
        XCTAssertFalse(app.staticTexts["Biggest change from last month"].exists)

        app.buttons["New"].tap()
        XCTAssertTrue(app.staticTexts["New"].exists)
    }

    func testMonthAnalysisKeepsChangesAndBalanceActionable() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()

        XCTAssertTrue(app.buttons["Month"].waitForExistence(timeout: 5))
        app.buttons["Month"].tap()
        XCTAssertTrue(element("insights-month-changes").waitForExistence(timeout: 10))
        XCTAssertTrue(element("insights-month-balance").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Recorded time by group"].exists)
        XCTAssertFalse(app.staticTexts["Meaningful differences from last month"].exists)
    }

    func testInsightsMonthBalanceSelectionAndDeselect() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()
        XCTAssertTrue(app.buttons["Month"].waitForExistence(timeout: 5))
        app.buttons["Month"].tap()
        XCTAssertTrue(element("insights-month-balance").waitForExistence(timeout: 10))

        let balance = element("insights-month-balance")
        let firstArea = balance.buttons.firstMatch
        XCTAssertTrue(firstArea.waitForExistence(timeout: 5))
        firstArea.tap()
        XCTAssertTrue(element("month-selected-balance").waitForExistence(timeout: 5))
        firstArea.tap()
        XCTAssertFalse(element("month-selected-balance").exists)
    }

    func testYearGroupChartHasSelectableLegendAndDrillDown() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()

        XCTAssertTrue(app.buttons["Year"].waitForExistence(timeout: 5))
        app.buttons["Year"].tap()
        XCTAssertTrue(element("annual-group-chart").waitForExistence(timeout: 10))
        let home = element("annual-group-Home")
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.tap()
        XCTAssertTrue(element("annual-selected-group").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Home"].exists)
        home.tap()
        XCTAssertFalse(element("annual-selected-group").exists)
    }

    func testYearPlacesUsesOneStableSelectedSegment() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()

        XCTAssertTrue(app.buttons["Year"].waitForExistence(timeout: 5))
        app.buttons["Year"].tap()
        var places = element("insights-year-places")
        var attempts = 0
        while !places.exists && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(places.waitForExistence(timeout: 5))
        XCTAssertTrue(element("year-place-picker").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Most time"].exists)
        XCTAssertTrue(app.buttons["Most visits"].exists)
        XCTAssertTrue(app.buttons["New places"].exists)
        XCTAssertTrue(app.buttons["Not visited"].exists)
        app.buttons["New places"].tap()
        XCTAssertTrue(app.staticTexts["New places"].exists)
    }

    func testYearHealthUsesFocusedSectionsAndUsefulUnavailableState() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()

        XCTAssertTrue(app.buttons["Year"].waitForExistence(timeout: 5))
        app.buttons["Year"].tap()
        var wellbeing = element("insights-year-wellbeing")
        var attempts = 0
        while !wellbeing.exists && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(wellbeing.waitForExistence(timeout: 5))
        XCTAssertTrue(element("year-health-picker").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Movement"].exists)
        XCTAssertTrue(app.buttons["Sleep"].exists)
        XCTAssertTrue(app.buttons["Workouts"].exists)
        XCTAssertTrue(app.staticTexts["Apple Health is not connected"].waitForExistence(timeout: 5))
    }

    /// Group and place drill-downs used to be sheets with their own throwaway
    /// `NavigationStack` -- reaching one from Year and another from Week/Month
    /// were two different presentation mechanisms for the same destination, and
    /// Back meant swiping a sheet away rather than popping. Both are pushed on
    /// the Insights tab's own stack now, through one `InsightsRoute`, so this
    /// proves the actual round trip -- push, land on the right screen, Back --
    /// returns to Year still selected, not to whatever period the tab defaults to.
    func testYearGroupAndPlaceDrillDownsPushAndReturnToYear() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()

        XCTAssertTrue(app.buttons["Year"].waitForExistence(timeout: 5))
        app.buttons["Year"].tap()
        XCTAssertTrue(element("annual-group-chart").waitForExistence(timeout: 10))

        let home = element("annual-group-Home")
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.tap()
        let openGroup = element("annual-selected-group")
        XCTAssertTrue(openGroup.waitForExistence(timeout: 5))
        openGroup.tap()

        XCTAssertTrue(element("insight-group-detail").waitForExistence(timeout: 5),
                      "the group drill-down must actually open, not just select the chart row")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["Year"].waitForExistence(timeout: 5),
                      "Back must return to Year, the period that was open, not reset to Day")
        XCTAssertTrue(element("annual-group-chart").waitForExistence(timeout: 5))

        var places = element("insights-year-places")
        var attempts = 0
        while !places.exists && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(places.waitForExistence(timeout: 5))
        let firstPlace = places.buttons.firstMatch
        XCTAssertTrue(firstPlace.waitForExistence(timeout: 5))
        firstPlace.tap()
        let openPlace = element("year-selected-place")
        XCTAssertTrue(openPlace.waitForExistence(timeout: 5))
        openPlace.tap()

        XCTAssertTrue(element("insight-place-history-detail").waitForExistence(timeout: 5),
                      "the place drill-down must actually open, not just select the row")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["Year"].waitForExistence(timeout: 5),
                      "Back must return to Year a second time, from a different drill-down")
    }
}
