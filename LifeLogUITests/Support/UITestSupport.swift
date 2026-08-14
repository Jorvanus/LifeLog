import XCTest

/// Shared fixture and helpers for every split `LifeLogUITests` class. Each
/// XCTest test method must live in its own `XCTestCase` subclass, but the
/// launch/seed/screenshot plumbing is identical across all of them, so it is
/// centralised here rather than copy-pasted per file.
class LifeLogUITestCase: XCTestCase {
    var app: XCUIApplication!

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
    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Every Insights visual fixture is built in memory. The extra flags select
    /// deterministic data only; they never request HealthKit, location, or a
    /// persisted preference left behind by another UI test.
    func launchSeededInsights(extraArguments: [String] = [], appearance: String? = nil,
                              contentSize: String? = nil) {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"] + extraArguments
        if let appearance {
            app.launchArguments += ["-AppleInterfaceStyle", appearance]
        }
        if let contentSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
        }
        app.launch()
        app.tabBars.buttons["Insights"].tap()
        XCTAssertTrue(element("insights-screen").waitForExistence(timeout: 10))
    }

    func recordInsightsScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
