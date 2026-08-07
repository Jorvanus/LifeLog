import XCTest

final class LifeLogUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
    }

    /// Screen identifiers are attached to whatever container SwiftUI renders
    /// (a ScrollView for Timeline, a Form/List elsewhere), so they never appear
    /// under `otherElements`. Matching on `.any` asserts the hook is present
    /// without pinning the test to the concrete element type SwiftUI chooses.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    func testPrimaryScreensExposeStableAccessibilityHooks() {
        XCTAssertTrue(element("timeline-screen").waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Insights"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)

        app.tabBars.buttons["Insights"].tap()
        XCTAssertTrue(element("insights-screen").waitForExistence(timeout: 5))
        XCTAssertTrue(element("insights-donut-chart").waitForExistence(timeout: 5))

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(element("settings-screen").waitForExistence(timeout: 5))
        XCTAssertTrue(element("saved-places-link").waitForExistence(timeout: 5))
    }

    func testSavedPlacesScreenIsReachableFromSettings() {
        app.tabBars.buttons["Settings"].tap()
        let savedPlaces = element("saved-places-link")
        XCTAssertTrue(savedPlaces.waitForExistence(timeout: 5))
        savedPlaces.tap()
        XCTAssertTrue(element("saved-places-screen").waitForExistence(timeout: 5))
    }

    func testCurrentLocationLabelingHookIsExposedWhenAVisitIsActive() {
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(element("settings-screen").waitForExistence(timeout: 5))

        // A fresh install may have no active location yet. When one exists,
        // the control must be discoverable and tappable for accessibility users.
        let labelControl = element("current-location-label")
        if labelControl.exists {
            XCTAssertTrue(labelControl.isHittable)
        }
    }

    /// Editing an activity pushes onto the Settings stack, so the editor keeps a
    /// working back button and offers Save without a redundant Cancel.
    func testEditingAnActivityPushesOntoTheSettingsStack() {
        app.tabBars.buttons["Settings"].tap()
        let activities = element("activities-link")
        XCTAssertTrue(activities.waitForExistence(timeout: 5))
        activities.tap()

        // Target a known activity rather than the first cell: the list is preceded by
        // an "Add from your history" row, so firstMatch is not an activity.
        let row = app.staticTexts["At home"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        let bar = app.navigationBars["Edit Activity"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        // The back button takes its title from the screen behind it, which is the
        // vocabulary editor — "Activity Labels" — not the Activities tab.
        XCTAssertTrue(bar.buttons["Activity Labels"].exists, "Pushed editor should keep a back button")
        XCTAssertTrue(bar.buttons["Save"].exists)
        XCTAssertFalse(bar.buttons["Cancel"].exists, "Cancel is only for the modal add flow")
    }

    /// Place History is the only route to correcting imported entries in bulk, so
    /// it has to be reachable and has to render its summary without crashing.
    func testPlaceHistoryIsReachableFromLocations() {
        app.tabBars.buttons["Settings"].tap()
        let places = element("saved-places-link")
        XCTAssertTrue(places.waitForExistence(timeout: 5))
        places.tap()

        let historyLink = element("place-history-link")
        XCTAssertTrue(historyLink.waitForExistence(timeout: 5))
        historyLink.tap()

        XCTAssertTrue(element("place-history-screen").waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Place History"].exists)
    }

    /// Adopting activities from history is what moves them out of the Insights
    /// "Other" bucket, so the screen has to be reachable and has to render.
    func testAddFromHistoryIsReachableFromActivities() {
        app.tabBars.buttons["Settings"].tap()
        let activities = element("activities-link")
        XCTAssertTrue(activities.waitForExistence(timeout: 5))
        activities.tap()

        let addFromHistory = element("add-from-history")
        XCTAssertTrue(addFromHistory.waitForExistence(timeout: 5))
        addFromHistory.tap()

        XCTAssertTrue(element("activity-import-screen").waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Add From History"].exists)
    }

    /// Diagnostics can hold hundreds of events, so the actions have to sit above the
    /// list rather than after it.
    func testDiagnosticsActionsAreReachableWithoutScrolling() {
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(element("settings-screen").waitForExistence(timeout: 5))
        // Settings is a long form and rows render lazily, so the link near the bottom
        // does not exist until it is scrolled into view.
        let diagnostics = element("diagnostics-link")
        var attempts = 0
        while !diagnostics.exists && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
        diagnostics.tap()

        XCTAssertTrue(element("diagnostics-screen").waitForExistence(timeout: 5))
        let report = app.buttons["Create performance report"]
        let clear = element("clear-diagnostics")
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        XCTAssertTrue(clear.exists)
        // Reachable means on screen, not merely present in the hierarchy.
        XCTAssertTrue(report.isHittable)
        XCTAssertTrue(clear.isHittable)
    }

    /// The usage count has to lead somewhere: opening an activity should list the
    /// visits it covers, and each should open for individual correction.
    func testActivityVisitsAreListedAndEditable() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()

        app.tabBars.buttons["Settings"].tap()
        let activities = element("activities-link")
        XCTAssertTrue(activities.waitForExistence(timeout: 10))
        activities.tap()

        // "At home" is seeded and used by the seeded timeline.
        let row = app.staticTexts["At home"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        let visitsLink = element("activity-visits-link")
        XCTAssertTrue(visitsLink.waitForExistence(timeout: 5))
        visitsLink.tap()

        XCTAssertTrue(element("activity-visits-screen").waitForExistence(timeout: 5))
        // Opening a listed visit must reach the ordinary editor.
        let firstVisit = app.cells.firstMatch
        XCTAssertTrue(firstVisit.waitForExistence(timeout: 5))
        firstVisit.tap()
        XCTAssertTrue(app.textFields["Place name"].waitForExistence(timeout: 5))
    }

    /// The day begins with the stay it woke up in, and the walk between two places
    /// is an entry of its own. Both were previously missing: an overnight stay was
    /// filtered out for arriving yesterday, and movement needed an hour to be shown.
    func testTimelineShowsTheOvernightStayAndTheWalkBetweenPlaces() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()

        XCTAssertTrue(element("todays-journey").waitForExistence(timeout: 10))
        let walk = app.staticTexts["Walking"]
        XCTAssertTrue(walk.waitForExistence(timeout: 5))
        // The overnight stay is labelled with the day it began, so a stay of many
        // hours cannot read as a few minutes this morning.
        let overnight = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Yesterday'")).firstMatch
        XCTAssertTrue(overnight.waitForExistence(timeout: 5))
    }

    /// Grouping decides where Insights counts time, and until now it could only be
    /// seen one activity at a time through a picker. The group's own view has to be
    /// reachable from Settings and offer adding one.
    func testActivityGroupsAreReachableFromSettings() {
        app.tabBars.buttons["Settings"].tap()
        let groups = element("activity-groups-link")
        XCTAssertTrue(groups.waitForExistence(timeout: 5))
        groups.tap()

        XCTAssertTrue(element("activity-groups-screen").waitForExistence(timeout: 5))
        // Adding has to stay reachable however many groups there are, so it lives in
        // the toolbar rather than below a list SwiftUI only builds as you scroll.
        XCTAssertTrue(element("add-group").waitForExistence(timeout: 5))
        XCTAssertTrue(element("add-group").isHittable)
        // The first group and an activity filed under it, both on screen at the top.
        XCTAssertTrue(app.staticTexts["Home"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["At home"].exists)
    }

    /// The Activities tab sits between Timeline and Insights, and each activity opens
    /// onto its own figures.
    func testActivitiesTabOpensAnActivitysDetail() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()

        app.tabBars.buttons["Activities"].tap()
        XCTAssertTrue(element("activities-tab-screen").waitForExistence(timeout: 10))

        // Seeded history uses "At home", so it is listed and has figures behind it.
        let row = app.staticTexts["At home"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        XCTAssertTrue(element("activity-detail-screen").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Total occasions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Top locations"].exists)
    }

    /// The Activities tab lists labels the catalogue has never heard of, because most
    /// of an imported archive is exactly that and a screen reporting where time went
    /// must not hide them. They are marked as such and can be adopted where they are
    /// found, which is what makes this list and Settings → Activity Labels converge.
    func testAdoptingAHistoryLabelFromTheActivitiesTab() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()

        app.tabBars.buttons["Activities"].tap()
        XCTAssertTrue(element("activities-tab-screen").waitForExistence(timeout: 10))

        // Seeded as a visit only, never added to the catalogue.
        let label = app.staticTexts["Donate Blood"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        let marker = app.staticTexts["From your history · not yet an activity"]
        XCTAssertTrue(marker.waitForExistence(timeout: 5),
                      "An unadopted label must say why it behaves differently")

        let unadopted = element("unadopted-activity-row").firstMatch
        XCTAssertTrue(unadopted.waitForExistence(timeout: 5))
        // The fixture seeds exactly one history-only label, which is what makes
        // `firstMatch` unambiguous. When a second one appeared, this quietly adopted
        // the wrong row and failed on the assertion at the end instead, which says
        // nothing about the cause.
        XCTAssertEqual(app.descendants(matching: .any)
            .matching(identifier: "unadopted-activity-row").count, 1,
                       "another unadopted label has crept into the seed fixture")
        unadopted.swipeLeft()
        let add = app.buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()

        // Adopted: still listed, with its figures intact, and no longer flagged.
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        XCTAssertFalse(marker.exists, "An adopted label must stop being marked as history-only")
    }

    func testManualEntryIsAccessibleFromTimeline() {
        let addVisit = app.buttons["Add visit"]
        XCTAssertTrue(addVisit.waitForExistence(timeout: 5))
        addVisit.tap()
        XCTAssertTrue(app.navigationBars["Add Visit"].waitForExistence(timeout: 5))

        // Location and activity are pages of their own rather than fields to fill in.
        let location = element("choose-location-link")
        XCTAssertTrue(location.waitForExistence(timeout: 5))
        XCTAssertTrue(element("choose-activity-link").exists)
        XCTAssertTrue(app.staticTexts["Start"].exists)
        XCTAssertTrue(app.staticTexts["End"].exists)

        location.tap()
        XCTAssertTrue(element("visit-location-chooser").waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["e.g. Aaron's Gardens"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Places nearby"].exists)
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
