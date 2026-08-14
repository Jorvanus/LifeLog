import XCTest

/// Timeline and Activities-tab workflows: visit editing, journey narrative,
/// manual entry, and adopting history-only labels into the catalogue.
final class TimelineAndActivitiesTests: LifeLogUITestCase {
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

        // Now below the editable fields (name, colour, category, icon) that the
        // merged detail/editor screen shows first, past what a lazy List
        // materialises without being scrolled to.
        let visitsLink = element("activity-visits-link")
        var attempts = 0
        while !visitsLink.exists && attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(visitsLink.waitForExistence(timeout: 5))
        visitsLink.tap()

        XCTAssertTrue(element("activity-visits-screen").waitForExistence(timeout: 5))
        // Opening a listed visit must reach the ordinary editor.
        let firstVisit = app.cells.firstMatch
        XCTAssertTrue(firstVisit.waitForExistence(timeout: 5))
        firstVisit.tap()
        XCTAssertTrue(element("choose-location-link").waitForExistence(timeout: 5))
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

        XCTAssertTrue(element("choose-location-link").waitForExistence(timeout: 5))
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

        let placeLink = element("choose-location-link")
        XCTAssertTrue(placeLink.waitForExistence(timeout: 5))
        XCTAssertFalse(element("visit-context-map").exists)
        placeLink.tap()

        XCTAssertTrue(element("visit-location-map-picker").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Tap the map to set or move this visit’s location."].exists)
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
        // The merged detail/editor screen puts the editable fields (name, colour,
        // category, icon) above the stats now, which pushes "Total occasions" past
        // what a lazy List materialises without being scrolled to first.
        let totalOccasions = app.staticTexts["Total occasions"]
        var attempts = 0
        while !totalOccasions.exists && attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(totalOccasions.waitForExistence(timeout: 5))
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
}
