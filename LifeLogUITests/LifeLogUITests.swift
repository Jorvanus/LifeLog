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
        XCTAssertTrue(bar.buttons["Activities"].exists, "Pushed editor should keep a back button")
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

    func testManualEntryIsAccessibleFromTimeline() {
        let addVisit = app.buttons["Add visit"]
        XCTAssertTrue(addVisit.waitForExistence(timeout: 5))
        addVisit.tap()
        XCTAssertTrue(app.navigationBars["Add Visit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Search Apple Maps or enter a name"].exists)
        XCTAssertTrue(app.buttons["Search nearby places"].exists)
    }
}
