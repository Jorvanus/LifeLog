import XCTest

/// Cross-cutting smoke tests that touch every primary tab rather than one
/// workflow — accessibility hooks and the full-tab screenshot matrix.
final class AccessibilitySmokeTests: LifeLogUITestCase {
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
