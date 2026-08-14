import XCTest

/// Insights at Day granularity: the current-activity card, the day bar and
/// donut, drill-downs, review sections, scope/date pickers, and the day
/// summary's metric visibility rules.
final class InsightsDayTests: LifeLogUITestCase {
    /// Insights opens on Day by default. The seeded open Home stay (`UITestSeedData`)
    /// is the Current Activity card's only reachability check — tapping it opens the
    /// same `VisitEditor` Timeline's own current-activity card opens.
    func testInsightsDayShowsCurrentActivityCard() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()
        let card = element("insights-current-activity-card")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(element("choose-location-link").waitForExistence(timeout: 5))
    }

    func testInsightsVisitDrillDownRestoresTheParentPeriod() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()
        XCTAssertTrue(element("insights-screen").waitForExistence(timeout: 5))
        let card = element("insights-current-activity-card")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(element("choose-location-link").waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element("insights-screen").waitForExistence(timeout: 5))
        XCTAssertTrue(element("insights-period-picker").exists)
    }

    func testInsightsTravelDrillDownKeepsSelectedPeriod() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()
        let travel = element("insights-travel-summary")
        var attempts = 0
        while !travel.exists && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(travel.waitForExistence(timeout: 5))
        let review = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Review ' AND label CONTAINS 'travel trips'" )).firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.tap()
        XCTAssertTrue(app.navigationBars["Travel trips"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("travel-selected-period").waitForExistence(timeout: 5))
    }

    /// The day bar is Day's primary visual — reachable, and distinct from the
    /// donut, which stays available lower on the same screen.
    func testInsightsDayTimelineBarAndDonutAreBothReachable() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()
        XCTAssertTrue(element("insights-day-bar").waitForExistence(timeout: 5))
        XCTAssertTrue(element("insights-donut-chart").waitForExistence(timeout: 5))
    }

    func testDayTimelineScreenshotCoversFutureGapSleepAndTravelStates() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed", "-ui-test-timeline-states"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()

        XCTAssertTrue(element("insights-day-bar").waitForExistence(timeout: 10))
        for label in ["Future time", "Unlogged time", "Sleep", "Travel"] {
            let segment = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH[c] %@", label))
                .firstMatch
            XCTAssertTrue(segment.waitForExistence(timeout: 5), "Missing DayTimelineBar state: \(label)")
        }

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "day-timeline-future-gap-sleep-travel"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDayTimelineScreenshotCoversNoDataState() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-empty"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()

        XCTAssertTrue(element("insights-day-bar").waitForExistence(timeout: 10))
        let noDataSegment = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH[c] 'Unlogged time'"))
            .firstMatch
        XCTAssertTrue(noDataSegment.waitForExistence(timeout: 5))

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "day-timeline-no-data"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testInsightsDayUsesDailyReviewSections() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()

        XCTAssertTrue(element("insights-current-activity-card").waitForExistence(timeout: 5))
        XCTAssertTrue(element("insights-day-bar").waitForExistence(timeout: 5))
        XCTAssertTrue(element("insights-day-summary").waitForExistence(timeout: 5))
        XCTAssertTrue(element("insights-needs-attention").waitForExistence(timeout: 5))
        XCTAssertTrue(element("day-highlights").waitForExistence(timeout: 5))
        XCTAssertTrue(element("insights-donut-chart").waitForExistence(timeout: 5))
    }

    func testInsightsActivitySelectionCanChangeDeselectRestoreAndDrillDown() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()

        var attempts = 0
        while !app.staticTexts["Top Activities"].exists && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(app.staticTexts["Top Activities"].waitForExistence(timeout: 5))
        let activities = app.buttons.matching(NSPredicate(format: "label CONTAINS 'percent of logged time'"))
        XCTAssertGreaterThanOrEqual(activities.count, 2)
        activities.element(boundBy: 0).tap()
        XCTAssertTrue(element("insights-selected-activity").waitForExistence(timeout: 5))
        activities.element(boundBy: 1).tap()
        XCTAssertTrue(element("insights-selected-activity").exists)
        activities.element(boundBy: 1).tap()
        XCTAssertFalse(element("insights-selected-activity").exists)

        app.swipeDown()
        app.swipeUp()
        activities.element(boundBy: 0).tap()
        XCTAssertTrue(element("insights-selected-activity").waitForExistence(timeout: 5))
        element("insights-selected-activity").tap()
        XCTAssertTrue(element("insight-activity-detail").waitForExistence(timeout: 5))
    }

    func testDaySummaryOmitsUnavailableMetricsWithoutZeroPlaceholders() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()

        XCTAssertTrue(element("insights-day-summary").waitForExistence(timeout: 5))
        let scope = element("insights-scope-picker")
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        scope.tap()
        XCTAssertTrue(app.buttons["All history"].waitForExistence(timeout: 5))
        app.buttons["All history"].tap()
        // The fixture intentionally contains multiple source types, so assert the
        // summary and its no-Health state without coupling this test to which
        // location segment wins resolution on a particular simulator runtime.
        XCTAssertTrue(element("insights-day-summary").exists)
        XCTAssertFalse(element("day-metric-steps").exists)
        XCTAssertFalse(element("day-metric-sleep").exists)
    }

    func testDaySummaryHidesHealthMetricsWhenScopeExcludesHealth() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()

        let scope = element("insights-scope-picker")
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        scope.tap()
        XCTAssertTrue(app.buttons["All history"].waitForExistence(timeout: 5))
        app.buttons["All history"].tap()
        scope.tap()
        XCTAssertTrue(app.buttons["Imported journal only"].waitForExistence(timeout: 5))
        app.buttons["Imported journal only"].tap()

        XCTAssertTrue(element("insights-day-summary").waitForExistence(timeout: 5))
        XCTAssertFalse(element("day-metric-steps").exists)
        XCTAssertFalse(element("day-metric-sleep").exists)
        XCTAssertFalse(element("day-metric-exercise").exists)
        XCTAssertFalse(element("day-metric-travel").exists)
    }

    /// The seeded unidentified and low-confidence stays give "Needs your
    /// attention" something to show without needing a fixture of its own.
    func testInsightsDayShowsNeedsAttentionForSeededIssues() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()
        XCTAssertTrue(element("insights-needs-attention").waitForExistence(timeout: 5))
    }

    func testInsightsDateButtonOpensTheDatePicker() {
        app.tabBars.buttons["Insights"].tap()
        XCTAssertTrue(element("insights-screen").waitForExistence(timeout: 10))

        let datePicker = element("insights-period-picker")
        XCTAssertTrue(datePicker.waitForExistence(timeout: 5))
        datePicker.tap()
        XCTAssertTrue(app.navigationBars["Choose Date"].waitForExistence(timeout: 5))

        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.navigationBars["Choose Date"].exists)

        datePicker.tap()
        XCTAssertTrue(app.navigationBars["Choose Date"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertFalse(app.navigationBars["Choose Date"].exists)
    }

    func testInsightsScopePickerPersistsAndShowsScopedEmptyState() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()

        let scopePicker = element("insights-scope-picker")
        XCTAssertTrue(scopePicker.waitForExistence(timeout: 10))
        scopePicker.tap()
        XCTAssertTrue(app.buttons["All history"].waitForExistence(timeout: 5))
        app.buttons["All history"].tap()

        scopePicker.tap()
        XCTAssertTrue(app.buttons["Imported journal only"].waitForExistence(timeout: 5))
        app.buttons["Imported journal only"].tap()
        let periodPicker = element("insights-period-picker")
        XCTAssertTrue(periodPicker.waitForExistence(timeout: 5))
        XCTAssertTrue(periodPicker.label.contains("Imported journal only"))
        XCTAssertTrue(element("insights-scope-empty-state").waitForExistence(timeout: 5))

        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed", "-ui-test-preserve-preferences"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()
        let relaunchedPeriodPicker = element("insights-period-picker")
        XCTAssertTrue(relaunchedPeriodPicker.waitForExistence(timeout: 10))
        XCTAssertTrue(relaunchedPeriodPicker.label.contains("Imported journal only"))

        // Leave the simulator's persistent preference at the product default for
        // the other deterministic UI tests in this target.
        let relaunchedScopePicker = element("insights-scope-picker")
        relaunchedScopePicker.tap()
        XCTAssertTrue(app.buttons["All history"].waitForExistence(timeout: 5))
        app.buttons["All history"].tap()
    }

    /// Starts on Day (gap and sleep drill-downs, donut selection) and continues
    /// through Week/Month/Year to confirm each period restores its own selection
    /// state after a drill-down — kept here because the day-level assertions are
    /// this test's largest and most detailed portion.
    func testInsightsDayBarDonutAndDrillDownsRestoreTheSelectedPeriod() {
        launchSeededInsights(extraArguments: ["-ui-test-timeline-states", "-ui-test-health-connected"])

        let gap = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH[c] 'Unlogged time'"))
            .firstMatch
        XCTAssertTrue(gap.waitForExistence(timeout: 10))
        gap.tap()
        XCTAssertTrue(element("insight-gap-detail").waitForExistence(timeout: 5))
        app.swipeDown()
        XCTAssertTrue(element("insights-period-picker").waitForExistence(timeout: 5))

        let sleep = element("day-metric-sleep")
        XCTAssertTrue(sleep.waitForExistence(timeout: 5))
        sleep.tap()
        XCTAssertTrue(element("insight-sleep-detail").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["LifeLog estimated score"].exists)
        app.swipeDown()
        XCTAssertTrue(element("insights-period-picker").waitForExistence(timeout: 5))

        let donutTarget = element("insights-donut-tap-target")
        XCTAssertTrue(donutTarget.waitForExistence(timeout: 5))
        let donutTap = donutTarget.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        donutTap.tap()
        XCTAssertTrue(element("insights-donut-selection").waitForExistence(timeout: 5))
        donutTap.tap()
        XCTAssertFalse(element("insights-donut-selection").exists)

        app.buttons["Week"].tap()
        let columns = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'logged'"))
        XCTAssertTrue(columns.firstMatch.waitForExistence(timeout: 10))
        columns.firstMatch.tap()
        XCTAssertTrue(element("weekly-selected-day").waitForExistence(timeout: 5))
        columns.firstMatch.tap()
        XCTAssertFalse(element("weekly-selected-day").exists)

        app.buttons["Month"].tap()
        XCTAssertTrue(element("insights-month-calendar").waitForExistence(timeout: 10))
        XCTAssertTrue(element("month-calendar-weekdays").exists)
        // `MonthlyInsightsTests` exercises all seven first-weekday offsets; this
        // UI assertion keeps the weekday header attached to the interactive grid.

        app.buttons["Year"].tap()
        let home = element("annual-life-area-Home")
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        home.tap()
        XCTAssertTrue(element("annual-selected-life-area").waitForExistence(timeout: 5))
        home.tap()
        XCTAssertFalse(element("annual-selected-life-area").exists)
    }
}
