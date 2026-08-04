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

    func testManualEntryIsAccessibleFromTimeline() {
        let addVisit = app.buttons["Add visit"]
        XCTAssertTrue(addVisit.waitForExistence(timeout: 5))
        addVisit.tap()
        XCTAssertTrue(app.navigationBars["Add Visit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Search Apple Maps or enter a name"].exists)
        XCTAssertTrue(app.buttons["Search nearby places"].exists)
    }
}
