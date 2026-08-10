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

        XCTAssertTrue(element("jump-to-date-button").waitForExistence(timeout: 10))
        let walk = app.staticTexts["Walking"]
        XCTAssertTrue(walk.waitForExistence(timeout: 5))
        // The overnight stay is labelled with the day it began, so a stay of many
        // hours cannot read as a few minutes this morning.
        let overnight = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Yesterday'")).firstMatch
        XCTAssertTrue(overnight.waitForExistence(timeout: 5))
    }

    /// A walk imported from Health has no coordinate and no route, so the editor used
    /// to show no map at all — for exactly the entries hardest to judge. It now shows
    /// the places recorded either side of it, which is what makes a walk that is really
    /// half an hour of shopping recognisable.
    func testAWalkWithNoPositionShowsThePlacesEitherSideOfIt() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()

        XCTAssertTrue(element("jump-to-date-button").waitForExistence(timeout: 10))
        // The card carries "Walking" twice, as the place name and as the activity, so
        // the query matches more than once and a bare tap is ambiguous. Both sit inside
        // the same entry and open the same editor.
        let walk = app.staticTexts["Walking"].firstMatch
        XCTAssertTrue(walk.waitForExistence(timeout: 5))
        walk.tap()

        XCTAssertTrue(app.textFields["Place name"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("visit-context-map").waitForExistence(timeout: 5))
        // And not the pin map, which would mean a position this record does not have.
        XCTAssertFalse(element("visit-location-map-picker").exists)
    }

    /// A hand-typed Add Visit entry with no coordinate is a different case from the
    /// walk above: there is nothing to protect it from a pin, and no way to give it
    /// one had to mean opening a different app entirely. It gets the editable map,
    /// not the read-only "places either side" context that a genuine device
    /// recording keeps.
    func testAManuallyTypedVisitWithNoCoordinateGetsAnEditableMap() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()

        XCTAssertTrue(element("jump-to-date-button").waitForExistence(timeout: 10))
        let bloodBank = app.staticTexts["Blood Bank"].firstMatch
        XCTAssertTrue(bloodBank.waitForExistence(timeout: 5))
        bloodBank.tap()

        XCTAssertTrue(app.textFields["Place name"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("visit-location-map-picker").waitForExistence(timeout: 5))
        XCTAssertFalse(element("visit-context-map").exists)
        XCTAssertTrue(app.staticTexts["Tap the map to set this visit’s location."].exists)
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

    /// The row announces that a label is not an activity yet, and tapping it is the
    /// obvious response. That used to land on a statistics page with no way to act on
    /// what had just been announced — the only remedy was a swipe mentioned once in a
    /// footer. The message and the remedy have to be in the same place.
    func testAdoptingAHistoryLabelFromItsOwnPage() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()

        app.tabBars.buttons["Activities"].tap()
        XCTAssertTrue(element("activities-tab-screen").waitForExistence(timeout: 10))

        let unadopted = element("unadopted-activity-row").firstMatch
        XCTAssertTrue(unadopted.waitForExistence(timeout: 5))
        unadopted.tap()

        XCTAssertTrue(element("activity-detail-screen").waitForExistence(timeout: 5))
        let add = element("adopt-activity-button")
        XCTAssertTrue(add.waitForExistence(timeout: 5),
                      "the page the warning links to must be able to act on the warning")
        add.tap()
        XCTAssertFalse(add.exists, "the offer must go once it has been taken")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element("activities-tab-screen").waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["From your history · not yet an activity"].exists,
                       "adopting on the detail page must reach the list behind it")
    }

    /// Timeline only ever showed today, so nine years of journal were reachable only
    /// as Insights aggregates — the history existed and could not be read.
    func testTimelineReadsPastDaysAsAJournal() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()

        XCTAssertTrue(element("timeline-screen").waitForExistence(timeout: 10))
        // The title is the button that opens the picker, so it is read as a control
        // rather than as static text. Asserting its label tests what is on screen and
        // what is tappable in one go.
        let dayTitle = element("jump-to-date-button")
        XCTAssertTrue(dayTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(dayTitle.label, "Today’s Journey")

        // On today there is nowhere to return from, so nothing offers to.
        XCTAssertFalse(element("today-button").exists)

        // Naming the day is the only way in: nine years is far too much history to
        // step through a day at a time.
        dayTitle.tap()
        XCTAssertTrue(element("jump-to-date-sheet").waitForExistence(timeout: 5))
        XCTAssertTrue(app.datePickers.firstMatch.exists, "the sheet must hold a calendar")
        app.buttons["Cancel"].tap()
        XCTAssertEqual(dayTitle.label, "Today’s Journey", "cancelling the picker stays put")

        dayTitle.tap()
        XCTAssertTrue(element("jump-to-date-sheet").waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        XCTAssertTrue(element("timeline-screen").waitForExistence(timeout: 5))
        XCTAssertEqual(dayTitle.label, "Today’s Journey", "dismissing without picking stays put")
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

    /// Keep visual evidence for the four primary tabs at the combinations that have
    /// actually exposed layout regressions: the normal and largest accessibility text
    /// sizes in both interface styles. XCTest's frame assertions cannot see text
    /// overlapping, clipping, or breaking into unreadable fragments, so these are kept
    /// as named attachments in the test result bundle for visual comparison.
    func testPrimaryTabsScreenshotMatrix() {
        let configurations: [(name: String, size: String?)] = [
            ("normal", nil),
            ("accessibility-xxxl", "UICTContentSizeCategoryAccessibilityXXXL")
        ]
        let appearances = [
            (name: "light", value: "Light"),
            (name: "dark", value: "Dark")
        ]
        let tabs = [
            (name: "timeline", identifier: "timeline-screen"),
            (name: "insights", identifier: "insights-screen"),
            (name: "activities", identifier: "activities-tab-screen"),
            (name: "settings", identifier: "settings-screen")
        ]

        for configuration in configurations {
            for appearance in appearances {
                app.terminate()
                app = XCUIApplication()
                app.launchArguments = [
                    "-uiTesting", "-ui-test-seed", "-AppleInterfaceStyle", appearance.value
                ]
                if let size = configuration.size {
                    app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
                }
                app.launch()

                for (index, tab) in tabs.enumerated() {
                    if index > 0 {
                        app.tabBars.buttons[tab.name.capitalized].tap()
                    }
                    XCTAssertTrue(element(tab.identifier).waitForExistence(timeout: 10),
                                  "\(tab.name) did not load for \(configuration.name)/\(appearance.name)")
                    if tab.name == "timeline" {
                        XCTAssertTrue(element("uncategorised-location-card").waitForExistence(timeout: 5),
                                      "seeded review card is missing from the Timeline capture")
                    } else if tab.name == "activities" {
                        XCTAssertTrue(app.staticTexts["Recently used"].waitForExistence(timeout: 5))
                        // At Accessibility XXXL the purpose sections are deliberately
                        // readable rather than compressed into one row, so the history
                        // section may be below the first viewport. Scroll to the
                        // crowded portion before taking the evidence capture.
                        var attempts = 0
                        while !app.staticTexts["From your history"].exists && attempts < 6 {
                            app.swipeUp()
                            attempts += 1
                        }
                        XCTAssertTrue(app.staticTexts["From your history"].waitForExistence(timeout: 5))
                    } else if tab.name == "settings" {
                        XCTAssertTrue(element("enable-location-logging").waitForExistence(timeout: 5),
                                      "Settings capture must show the initial permission state")
                    }
                    let screenshot = XCUIScreen.main.screenshot()
                    let attachment = XCTAttachment(screenshot: screenshot)
                    attachment.name = "\(tab.name)-\(configuration.name)-\(appearance.name)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }
}
