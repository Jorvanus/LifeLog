import XCTest

/// The seeded end-to-end path: Repair Archive → Unlogged Time → the one seeded
/// gap → "Help me classify this gap" → a real, deterministic candidate (built
/// by `GapSuggestionContextBuilder` from the `-ui-test-gap-suggestion` fixture's
/// actual Home/Work-role Saved Places) ranked by `FakeGapSuggestionService`
/// (never live Apple Intelligence) → "Use as draft" → the ordinary, editable
/// Manual Visit form, saved explicitly.
final class GapSuggestionUITests: LifeLogUITestCase {
    /// This fixture's own "Regional Office HQ" visit also borders the
    /// archive's next chronological visit (the base seed's "Sleep", 19 days
    /// later), which — being far beyond `ArchiveRepair.gapFillCap` — is itself
    /// reported as a second, separate unlogged gap. Matching on "Regional
    /// Office HQ" alone is therefore ambiguous between the two; the full
    /// "Home … and Regional Office HQ" phrasing is unique to the one intended
    /// gap. (The default fixture can also surface an unrelated gap of its own
    /// depending on the wall-clock time the test happens to run at — its
    /// "today" visits are placed from 08:00 on, the same clock-dependence
    /// `InsightsDayTests` already works around — which is the other reason
    /// this can't just assume its row is the only one in the list.)
    private var seededGapRow: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Home (At home) and Regional Office HQ")).firstMatch
    }

    private func launchAtUnloggedGap() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting", "-ui-test-seed", "-ui-test-gap-suggestion",
            "-ui-test-gap-suggestion-fake", "-ui-test-open-archive-repair",
        ]
        app.launch()

        XCTAssertTrue(element("archive-repair-screen").waitForExistence(timeout: 10))
        element("repair-scan").tap()
        XCTAssertTrue(element("review-unlogged-gaps-link").waitForExistence(timeout: 10))
        element("review-unlogged-gaps-link").tap()

        XCTAssertTrue(element("unlogged-gaps-screen").waitForExistence(timeout: 10))
        XCTAssertTrue(seededGapRow.waitForExistence(timeout: 10))
        seededGapRow.tap()
    }

    func testHelpMeClassifyAcceptedSuggestionSavesAsEditableManualVisit() {
        launchAtUnloggedGap()

        XCTAssertTrue(element("gap-suggestion-request-button").waitForExistence(timeout: 10))
        element("gap-suggestion-request-button").tap()

        XCTAssertTrue(element("gap-suggestion-headline").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Possible transition between Home and Regional Office HQ."].exists)
        XCTAssertTrue(element("gap-suggestion-confidence").exists)
        XCTAssertTrue(element("gap-suggestion-explanation").exists)

        element("gap-suggestion-use-as-draft").tap()

        // The card collapses back to its starting button — the draft now lives
        // in the ordinary, editable form fields below, not in a still-pending
        // suggestion.
        XCTAssertTrue(element("gap-suggestion-request-button").waitForExistence(timeout: 5))
        // `LabeledContent`'s label and value merge into one accessibility
        // string ("Location, Home → Regional Office HQ"), so these match on
        // the identifier and check the combined label contains the value
        // rather than expecting the value alone.
        let locationLink = element("choose-location-link")
        XCTAssertTrue(locationLink.waitForExistence(timeout: 5))
        XCTAssertTrue(locationLink.label.contains("Home → Regional Office HQ"))
        XCTAssertTrue(element("choose-activity-link").label.contains("Commuting"))

        // Still an ordinary, editable Manual Visit — explicit Save required.
        app.buttons["Save"].tap()

        XCTAssertFalse(element("gap-suggestion-request-button").waitForExistence(timeout: 2))
        XCTAssertTrue(element("unlogged-gaps-screen").waitForExistence(timeout: 10))
        // The gap this test filled is gone from the list.
        XCTAssertFalse(seededGapRow.waitForExistence(timeout: 5))
    }

    func testNotRightDismissesTheSuggestionWithoutTouchingTheGap() {
        launchAtUnloggedGap()

        XCTAssertTrue(element("gap-suggestion-request-button").waitForExistence(timeout: 10))
        element("gap-suggestion-request-button").tap()
        XCTAssertTrue(element("gap-suggestion-headline").waitForExistence(timeout: 10))

        element("gap-suggestion-not-right").tap()
        XCTAssertTrue(element("gap-suggestion-request-button").waitForExistence(timeout: 5))
        // Declining a suggestion must never populate the manual form on its own.
        XCTAssertFalse(element("choose-location-link").label.contains("Regional Office HQ"))

        app.buttons["Cancel"].tap()
        XCTAssertTrue(element("unlogged-gaps-screen").waitForExistence(timeout: 10))
        // The gap is still there — nothing was saved.
        XCTAssertTrue(seededGapRow.waitForExistence(timeout: 5))
    }
}

