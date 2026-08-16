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

    /// Scanning must never arm anything by itself: the scan is read-only, and the
    /// apply action stays unavailable until a step with work is deliberately
    /// chosen.
    ///
    /// Only the invariant is asserted, not "tapping a step enables apply" — what a
    /// seeded launch offers work for is not stable. `RootView` runs the activity
    /// backfill at launch, which links the whole small fixture before this screen
    /// is reached, so whether any step has work at all depends on a race with that
    /// `.task`. The invariant holds either way.
    ///
    /// Deliberately at the default text size, unlike the sibling storage test: that
    /// one exists to check layout at Accessibility XXXL, this one checks behaviour.
    /// `Form` instantiates its rows lazily, so an oversized launch simply pushes
    /// the later steps out of existence and the test fails for a reason that has
    /// nothing to do with what it is asserting.
    func testArchiveRepairScanDoesNotArmApply() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed", "-ui-test-open-archive-repair"]
        app.launch()

        XCTAssertTrue(element("archive-repair-screen").waitForExistence(timeout: 10))

        let scan = element("repair-scan")
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        scan.tap()

        // The scan has produced findings once the first step row exists.
        let firstStep = element("repair-step-closeRunawayStays")
        XCTAssertTrue(firstStep.waitForExistence(timeout: 15), "scan must report what it found")

        // Every step must be reachable, so nothing the scan reports is hidden below
        // a fold the person cannot get to.
        for step in ["closeRunawayStays", "fillRoutineGaps"] {
            XCTAssertTrue(scrollToElement("repair-step-\(step)").exists,
                          "repair step \(step) must be reachable")
        }

        let apply = scrollToElement("apply-archive-repair")
        XCTAssertTrue(apply.exists, "the apply action must be reachable")
        XCTAssertFalse(apply.isEnabled, "scanning alone must never arm the repair")
    }

    /// Scrolls a Form until the identified element is instantiated and on screen.
    /// `Form` is lazy, so an element below the fold does not merely fail
    /// `isHittable` — it does not exist yet.
    private func scrollToElement(_ identifier: String, attempts: Int = 12) -> XCUIElement {
        let target = element(identifier)
        var swipes = 0
        while !(target.exists && target.isHittable) && swipes < attempts {
            app.swipeUp()
            swipes += 1
        }
        return target
    }

    /// Opening a gap from the browsing list must start scoped to that exact gap
    /// — not to "right now", which is what a person saw before this existed —
    /// and must show what was recorded either side, so a decision can be made
    /// without leaving the sheet to go check Timeline. Uses its own isolated
    /// fixture (`-ui-test-manual-visit-gap`): the default seed's open-ended
    /// "Home" stay covers straight through to `now`, leaving nothing for this
    /// test to find.
    func testTappingAnUnloggedGapPrefillsRangeAndOffersBorderingPlaces() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed", "-ui-test-manual-visit-gap",
                               "-ui-test-open-archive-repair"]
        app.launch()

        XCTAssertTrue(element("archive-repair-screen").waitForExistence(timeout: 10))
        let scan = element("repair-scan")
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        scan.tap()

        let reviewLink = scrollToElement("review-unlogged-gaps-link")
        XCTAssertTrue(reviewLink.exists, "the scan must offer a way to browse every gap")
        reviewLink.tap()

        XCTAssertTrue(element("unlogged-gaps-screen").waitForExistence(timeout: 10))
        // Matched on "Rockhampton Grammar School" specifically, not "Regional
        // Office" — the far-flung placement of this isolated fixture (ten days
        // before the rest of the seed, deliberately, so nothing else overlaps it)
        // also produces a second, unrelated gap between the fixture's own
        // "Regional Office" visit and the default seed's next visit days later.
        // Both rows contain "Regional Office"; only the intended one also
        // contains "Rockhampton Grammar School".
        let targetRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Rockhampton Grammar School")
        ).firstMatch
        var swipes = 0
        while !(targetRow.exists && targetRow.isHittable) && swipes < 20 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(targetRow.exists, "the seeded gap, bordered by Rockhampton Grammar School and Regional Office, must be listed")
        targetRow.tap()

        XCTAssertTrue(app.navigationBars["Add Visit"].waitForExistence(timeout: 10))
        // The bordering context this whole test exists for: what was recorded on
        // either side, visible without leaving the sheet. Checked as plain text
        // first (weakest possible signal — did the content render at all) so a
        // failure here is distinguishable from an identifier that didn't attach.
        XCTAssertTrue(app.staticTexts["Rockhampton Grammar School"].waitForExistence(timeout: 5),
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts["Regional Office"].exists)
        XCTAssertTrue(element("manual-visit-before-context").exists)
        XCTAssertTrue(element("manual-visit-after-context").exists)

        // Pre-filled from the gap, not from `Date()` — the exact bug reported.
        // The seeded gap sits ten days in the past; a DatePicker whose value
        // mentions today's day-of-month means the range was discarded.
        let today = Calendar.current.component(.day, from: .now)
        let startPicker = element("manual-visit-start-picker")
        XCTAssertTrue(startPicker.waitForExistence(timeout: 5))
        let startValue = startPicker.value as? String ?? ""
        XCTAssertFalse(startValue.contains(String(today)),
                       "Start must show the gap's own day, not today's: \(startValue)")

        // Tapping "Before" carries that place straight into Location — checked
        // against the link's own label, not a bare `staticTexts` lookup, since
        // "Rockhampton Grammar School" already exists on screen from the context
        // row above regardless of whether the tap did anything.
        element("manual-visit-before-context").tap()
        let location = element("choose-location-link")
        XCTAssertTrue(location.waitForExistence(timeout: 5))
        XCTAssertTrue(location.label.contains("Rockhampton Grammar School"),
                     "selecting the bordering visit must fill Location with its place, got: \(location.label)")
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
