import XCTest

final class LaunchAndNavigationTests: XCTestCase {
    func testLaunchesAndVisitsEveryTab() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["WORLD TREE AI"].waitForExistence(timeout: 15))
        let expectedTitles = ["World Tree": "World Tree", "AI Research": "AI Research", "Famous": "Famous Families",
                              "Discoveries": "Discoveries", "Profile": "Profile", "Home": "WORLD TREE AI"]
        for tab in ["World Tree", "AI Research", "Famous", "Discoveries", "Profile", "Home"] {
            let button = app.buttons["tab-\(tab)"]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "missing tab \(tab)")
            button.tap()
            XCTAssertTrue(app.navigationBars[expectedTitles[tab]!].waitForExistence(timeout: 5), "tab \(tab) did not open")
        }
        app.buttons["tab-Profile"].tap()
        XCTAssertTrue(app.buttons["Import GEDCOM (.ged)"].waitForExistence(timeout: 5))
    }
}
