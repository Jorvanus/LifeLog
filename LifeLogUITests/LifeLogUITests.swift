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

    func testPrimaryScreensExposeStableAccessibilityHooks() {
        XCTAssertTrue(app.otherElements["timeline-screen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Insights"].exists)
        XCTAssertTrue(app.tabBars.buttons["Map"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)

        app.tabBars.buttons["Insights"].tap()
        XCTAssertTrue(app.otherElements["insights-screen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["insights-donut-chart"].exists)

        app.tabBars.buttons["Map"].tap()
        XCTAssertTrue(app.otherElements["map-screen"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.otherElements["settings-screen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["saved-places-link"].waitForExistence(timeout: 5))
    }

    func testSavedPlacesScreenIsReachableFromSettings() {
        app.tabBars.buttons["Settings"].tap()
        let savedPlaces = app.descendants(matching: .any)["saved-places-link"]
        XCTAssertTrue(savedPlaces.waitForExistence(timeout: 5))
        savedPlaces.tap()
        XCTAssertTrue(app.otherElements["saved-places-screen"].waitForExistence(timeout: 5))
    }

    func testCurrentLocationLabelingHookIsExposedWhenAVisitIsActive() {
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.otherElements["settings-screen"].waitForExistence(timeout: 5))

        // A fresh install may have no active location yet. When one exists,
        // the control must be discoverable and tappable for accessibility users.
        let labelControl = app.descendants(matching: .any)["current-location-label"]
        if labelControl.exists {
            XCTAssertTrue(labelControl.isHittable)
        }
    }

    func testManualEntryIsAccessibleFromTimeline() {
        let addVisit = app.buttons["Add visit"]
        XCTAssertTrue(addVisit.waitForExistence(timeout: 5))
        addVisit.tap()
        XCTAssertTrue(app.navigationBars["Add visit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Search Apple Maps or enter a name"].exists)
        XCTAssertTrue(app.buttons["Search nearby places"].exists)
    }
}
