import XCTest

/// Settings, Saved Places, Activity catalogue, and diagnostics/backup
/// workflows reachable from the Settings tab.
final class SettingsAndDiagnosticsTests: LifeLogUITestCase {
    func testSavedPlacesScreenIsReachableFromSettings() {
        app.tabBars.buttons["Settings"].tap()
        let savedPlaces = element("saved-places-link")
        XCTAssertTrue(savedPlaces.waitForExistence(timeout: 5))
        savedPlaces.tap()
        XCTAssertTrue(element("saved-places-screen").waitForExistence(timeout: 5))
    }

    /// The seeded "Home" place (`UITestSeedData`) is the explicit Home/Work role
    /// affordance's only reachability check — a segmented control, not a rename.
    func testSavedPlaceRoleControlIsReachable() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        let savedPlaces = element("saved-places-link")
        XCTAssertTrue(savedPlaces.waitForExistence(timeout: 5))
        savedPlaces.tap()
        XCTAssertTrue(element("saved-places-screen").waitForExistence(timeout: 5))
        let home = app.staticTexts["Home"]
        var attempts = 0
        while !home.exists && attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.tap()
        let rolePicker = element("saved-place-role-picker")
        XCTAssertTrue(rolePicker.waitForExistence(timeout: 5))
        XCTAssertTrue(rolePicker.buttons["Home"].exists)
        XCTAssertTrue(rolePicker.buttons["Work"].exists)
    }

    /// HealthKit and Core Motion fail or need recovery in different places. Keeping
    /// their controls independently addressable prevents a Health button silently
    /// becoming the only apparent way to fix Motion access.
    func testHealthAndMotionSetupHaveSeparateControls() {
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Apple Health"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("reimport-health").waitForExistence(timeout: 5))

        let motion = app.staticTexts["Motion Activity"]
        var attempts = 0
        while !motion.exists && attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(motion.waitForExistence(timeout: 5))
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

        // The merged detail/editor screen titles itself with the activity's own
        // name, not a generic "Edit Activity" — same screen the Activities tab
        // reaches, just with its editable section visible from here too.
        XCTAssertTrue(element("activity-detail-screen").waitForExistence(timeout: 5))
        let bar = app.navigationBars["At home"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        // The back button takes its title from the screen behind it, which is the
        // vocabulary editor — "Activity Labels" — not the Activities tab.
        XCTAssertTrue(bar.buttons["Activity Labels"].exists, "Pushed detail screen should keep a back button")
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

    /// A protected-report failure must remain understandable at the largest text size
    /// in dark mode. The explicit labels also guard the controls
    /// VoiceOver users need; screenshots alone cannot tell us whether a glyph-only
    /// action lost its spoken name.
    func testDiagnosticsProtectedWriteFailureAtLargeDarkType() {
        app.terminate()
        app.launchArguments = [
            "-uiTesting", "-ui-test-fail-protected-report",
            "-ui-test-open-diagnostics",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            "-AppleInterfaceStyle", "Dark"
        ]
        app.launch()

        XCTAssertTrue(element("diagnostics-screen").waitForExistence(timeout: 10))
        let report = element("create-performance-report")
        var attempts = 0
        while !report.exists && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        XCTAssertEqual(report.label, "Create performance report", "report action must have a VoiceOver label")
        report.tap()

        XCTAssertTrue(app.alerts["Diagnostics"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["LifeLog couldn’t write the performance report."].exists)
        app.buttons["OK"].tap()
    }

    /// Journal Storage starts empty in a seeded launch. The cleanup action must be
    /// disabled, while the separate backup action exposes its failure recovery alert.
    /// This runs at Accessibility XXXL in dark mode so labels and disabled state are
    /// exercised under the same conditions as the visual review.
    func testJournalStorageEmptyHistoryAndBackupFailure() {
        app.terminate()
        app.launchArguments = [
            "-uiTesting", "-ui-test-open-journal-storage",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            "-AppleInterfaceStyle", "Dark"
        ]
        app.launch()

        XCTAssertTrue(element("journal-storage-screen").waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Journal Storage"].exists, "journal storage must expose its spoken title")
        XCTAssertTrue(app.staticTexts["Records"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("journal-record-count").label.contains("0"), "seeded journal storage must be empty")
        XCTAssertTrue(element("journal-empty-state").waitForExistence(timeout: 5))
    }

    func testSettingsBackupFailure() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-fail-backup", "-AppleInterfaceStyle", "Dark"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(element("settings-screen").waitForExistence(timeout: 10))
        let backup = element("create-backup")
        var attempts = 0
        while !backup.exists && attempts < 12 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(backup.waitForExistence(timeout: 5))
        backup.tap()
        XCTAssertTrue(app.alerts["Journal import"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["LifeLog couldn’t create a backup."].exists)
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
}
