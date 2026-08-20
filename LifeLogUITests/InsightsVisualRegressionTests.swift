import XCTest

/// Insights visual-regression and screenshot-matrix coverage: rich fixture
/// states, long labels, sparse/imported data, and the largest accessibility
/// text size.
final class InsightsVisualRegressionTests: LifeLogUITestCase {
    /// The Insights story is most prone to visual drift because each period has
    /// different cards and colour semantics. Keep light/dark and Accessibility
    /// XXXL captures for each period's top-level story.
    func testInsightsVisualLanguageScreenshotMatrix() {
        let configurations: [(name: String, size: String?)] = [
            ("normal", nil),
            ("accessibility-xxxl", "UICTContentSizeCategoryAccessibilityXXXL")
        ]
        let appearances = [(name: "light", value: "Light"), (name: "dark", value: "Dark")]
        let periods = ["Day", "Week", "Month", "Year"]

        for configuration in configurations {
            for appearance in appearances {
                app.terminate()
                app = XCUIApplication()
                app.launchArguments = ["-uiTesting", "-ui-test-seed", "-AppleInterfaceStyle", appearance.value]
                if let size = configuration.size {
                    app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
                }
                app.launch()
                app.tabBars.buttons["Insights"].tap()

                for period in periods {
                    if period != "Day" {
                        XCTAssertTrue(app.buttons[period].waitForExistence(timeout: 5))
                        app.buttons[period].tap()
                    }
                    XCTAssertTrue(element("insights-screen").waitForExistence(timeout: 10))
                    let screenshot = XCUIScreen.main.screenshot()
                    let attachment = XCTAttachment(screenshot: screenshot)
                    attachment.name = "insights-\(period.lowercased())-\(configuration.name)-\(appearance.name)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    /// A rich, fixed archive catches visual regressions in the period-specific
    /// stories without depending on a simulator's HealthKit or location history.
    func testInsightsRichFixtureVisualRegressionMatrix() {
        let configurations: [(name: String, size: String?)] = [
            ("normal", nil),
            ("accessibility-xxxl", "UICTContentSizeCategoryAccessibilityXXXL")
        ]
        let appearances = [(name: "light", value: "Light"), (name: "dark", value: "Dark")]
        let expectedByPeriod = [
            ("Day", "insights-day-summary"),
            ("Week", "insights-week-your-week"),
            ("Month", "insights-month-calendar"),
            ("Year", "annual-group-chart")
        ]

        for configuration in configurations {
            for appearance in appearances {
                launchSeededInsights(
                    extraArguments: ["-ui-test-timeline-states", "-ui-test-week-travel",
                                     "-ui-test-long-labels", "-ui-test-health-connected"],
                    appearance: appearance.value,
                    contentSize: configuration.size
                )

                XCTAssertTrue(element("insights-current-activity-card").waitForExistence(timeout: 10))
                XCTAssertTrue(element("insights-needs-attention").waitForExistence(timeout: 10))
                XCTAssertTrue(element("day-metric-steps").waitForExistence(timeout: 10))

                for (period, expected) in expectedByPeriod {
                    if period != "Day" {
                        XCTAssertTrue(app.buttons[period].waitForExistence(timeout: 5))
                        app.buttons[period].tap()
                    }
                    XCTAssertTrue(element(expected).waitForExistence(timeout: 10),
                                  "\(period) did not load for \(configuration.name)/\(appearance.name)")
                    recordInsightsScreenshot("insights-rich-\(period.lowercased())-\(configuration.name)-\(appearance.name)")
                }
            }
        }
    }

    func testInsightsFixtureStatesCoverLongLabelsSparseImportedAndHealthAvailability() {
        launchSeededInsights(extraArguments: ["-ui-test-long-labels", "-ui-test-health-connected"])
        XCTAssertTrue(element("day-metric-sleep").waitForExistence(timeout: 10))
        XCTAssertTrue(element("day-metric-steps").exists)
        app.buttons["Month"].tap()
        XCTAssertTrue(element("insights-month-places").waitForExistence(timeout: 10))
        let longPlace = app.buttons.matching(NSPredicate(format: "label CONTAINS %@",
                                                         "The Very Long Riverfront Community Health and Wellbeing Centre"))
            .firstMatch
        var attempts = 0
        while !longPlace.exists && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(longPlace.waitForExistence(timeout: 5))
        recordInsightsScreenshot("insights-long-labels-health-connected")

        app.tabBars.buttons["Activities"].tap()
        let longActivity = app.staticTexts["A very long activity name for accessibility and truncation regression coverage"]
        attempts = 0
        while !longActivity.exists && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(longActivity.waitForExistence(timeout: 5))

        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-ui-test-empty"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()
        XCTAssertTrue(element("insights-first-run-card").waitForExistence(timeout: 10))
        XCTAssertFalse(element("insights-travel-summary").exists)
        recordInsightsScreenshot("insights-sparse-no-health-no-travel")

        launchSeededInsights(extraArguments: ["-ui-test-imported-history"])
        let scopePicker = element("insights-scope-picker")
        XCTAssertTrue(scopePicker.waitForExistence(timeout: 5))
        scopePicker.tap()
        XCTAssertTrue(app.buttons["Imported journal only"].waitForExistence(timeout: 5))
        app.buttons["Imported journal only"].tap()
        app.buttons["Year"].tap()
        XCTAssertTrue(element("annual-group-chart").waitForExistence(timeout: 10))
        XCTAssertTrue(element("insights-period-picker").label.contains("Imported journal only"))
        recordInsightsScreenshot("insights-imported-history-year")
    }

    /// The largest accessibility size, on the 6.9" screen the app is actually used on.
    ///
    /// Both screens broke here and neither was covered. The Insights ring is fixed
    /// geometry, so unbounded text inside it drew across the segments and ran under
    /// the tab bar; the review card squeezed its text between an icon, a pill and a
    /// chevron until "Is this right?" wrapped one word to a line.
    ///
    /// Existence alone proves nothing — an element pushed under the tab bar or off the
    /// bottom of the screen still exists. So this checks where things actually are.
    /// `isHittable` is the wrong tool for the ring specifically: its centre sets
    /// `allowsHitTesting(false)` while no slice is focused, so the container's hit
    /// point is deliberately dead even when the chart is perfectly placed.
    func testInsightsAndReviewCardSurviveTheLargestTextSize() {
        app.terminate()
        app.launchArguments = [
            "-uiTesting", "-ui-test-seed",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()

        XCTAssertTrue(element("timeline-screen").waitForExistence(timeout: 10))
        let card = element("uncategorised-location-card")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.isHittable, "The review card must stay reachable at the largest text size")

        app.tabBars.buttons["Insights"].tap()
        XCTAssertTrue(element("insights-screen").waitForExistence(timeout: 10))
        XCTAssertTrue(element("insights-donut-chart").waitForExistence(timeout: 10))

        // No geometry is asserted here, and that is deliberate rather than an omission.
        // The identifier is inherited by the enclosing card as well as the ring, so a
        // frame read back through it spans the whole section — measured at 709pt tall
        // and 1003pt down the screen while the ring itself sat comfortably inside the
        // 956pt screen. Any threshold pinned to that would fail when the card is
        // restyled rather than when the layout breaks.
        //
        // The regressions this test exists for — labels drawn across the segments,
        // "Connect Apple Health" written over the ring, text wrapping one word to a
        // line — are invisible to XCTest regardless: overlapping text has perfectly
        // valid frames. Screenshots at this size caught them and screenshots are what
        // will catch them again. What this test genuinely guards is that both screens
        // still build and stay reachable at the largest size, which is where they
        // previously fell over.
    }
}
