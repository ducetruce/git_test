import XCTest

/// Walks the main screens against the fake robot and attaches a screenshot
/// of each, so CI shows how they render. It checks nothing about layout:
/// look at the screenshots.
final class ScreenshotTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = true
        app.launchArguments = ["-robotHost", "127.0.0.1", "-launchInProgress", "NO"]
        app.launch()
    }

    func testMainScreens() {
        // Give the app time to wake the fake robot and load its map.
        sleep(15)
        for tab in ["Today", "Clean", "Station", "More"] {
            app.tabBars.buttons[tab].tap()
            sleep(3)
            shot(tab)
        }
        for row in ["Schedules", "Freo Mind Mode", "Floor Cleaning", "Dock", "Navo Voice Assistant", "Device"] {
            open(row)
        }
    }

    /// Opens a row under More, screenshots it and goes back.
    private func open(_ row: String) {
        app.tabBars.buttons["More"].tap()
        let link = app.buttons[row]
        for _ in 0..<6 where !link.isHittable { app.swipeUp() }
        guard link.isHittable else { return shot("Missing - \(row)") }
        link.tap()
        sleep(3)
        shot("More - \(row)")
        app.navigationBars.buttons.firstMatch.tap()
        for _ in 0..<6 where !app.buttons["Schedules"].isHittable { app.swipeDown() }
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
