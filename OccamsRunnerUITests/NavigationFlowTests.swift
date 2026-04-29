import XCTest

/// UI tests for non-AR screens. Runs in iOS Simulator (no device required).
/// The AR screen is NOT tested here — it requires a physical device and camera.
///
/// Setup: The app is launched with UI_TESTING=1 so it uses an isolated temp directory.
/// LOAD_FIXTURE_ROUTES=1 pre-populates two routes and one quest for data-dependent tests.
final class NavigationFlowTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launchEnvironment["LOAD_FIXTURE_ROUTES"] = "1"
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Tab bar

    func test_tabBar_hasFourTabs() {
        XCTAssertEqual(app.tabBars.firstMatch.buttons.count, 4)
    }

    func test_defaultTab_showsHomeUI() {
        // Home tab is the first tab. It shows the dashboard.
        XCTAssertTrue(app.tabBars.buttons["Home"].isSelected)
    }

    func test_tapRoutesTab_showsRoutesTitle() {
        app.tabBars.buttons["Routes"].tap()
        XCTAssertTrue(app.staticTexts["Routes Library"].waitForExistence(timeout: 3))
    }

    func test_tapQuestsTab_showsQuestsTitle() {
        app.tabBars.buttons["Quests"].tap()
        XCTAssertTrue(app.staticTexts["Quest Library"].waitForExistence(timeout: 3))
    }

    // MARK: - Routes list

    func test_routesTab_withFixtureData_showsRoutesList() {
        app.tabBars.buttons["Routes"].tap()
        // Fixture data has two routes: "Morning Loop" and "Hill Climb"
        XCTAssertTrue(app.staticTexts["Morning Loop"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Hill Climb"].exists)
    }

    func test_routesTab_routeRow_showsDistanceLabel() {
        app.tabBars.buttons["Routes"].tap()
        XCTAssertTrue(app.staticTexts["Morning Loop"].waitForExistence(timeout: 3))
        // Route rows show distance in miles (e.g. "0.19 MILES")
        let miLabel = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'mi'")).firstMatch
        XCTAssertTrue(miLabel.exists)
    }

    func test_tapRoute_navigatesToRouteDetail() {
        app.tabBars.buttons["Routes"].tap()
        XCTAssertTrue(app.staticTexts["Morning Loop"].waitForExistence(timeout: 3))
        app.staticTexts["Morning Loop"].tap()
        // RouteDetailView should appear with a Create Quest button
        XCTAssertTrue(app.buttons["Create Quest"].waitForExistence(timeout: 3))
    }

    func test_routeDetail_hasView3DButton() {
        app.tabBars.buttons["Routes"].tap()
        XCTAssertTrue(app.staticTexts["Morning Loop"].waitForExistence(timeout: 3))
        app.staticTexts["Morning Loop"].tap()
        XCTAssertTrue(app.buttons["View in 3D"].waitForExistence(timeout: 3))
    }

    // MARK: - Quest creation

    func test_createQuest_sheetAppears() {
        app.tabBars.buttons["Routes"].tap()
        XCTAssertTrue(app.staticTexts["Morning Loop"].waitForExistence(timeout: 3))
        app.staticTexts["Morning Loop"].tap()
        XCTAssertTrue(app.buttons["Create Quest"].waitForExistence(timeout: 3))
        app.buttons["Create Quest"].tap()
        // Quest creator sheet should appear with a name field
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 3))
    }

    func test_createQuest_cancelDismissesSheet() {
        app.tabBars.buttons["Routes"].tap()
        XCTAssertTrue(app.staticTexts["Morning Loop"].waitForExistence(timeout: 3))
        app.staticTexts["Morning Loop"].tap()
        XCTAssertTrue(app.buttons["Create Quest"].waitForExistence(timeout: 3))
        app.buttons["Create Quest"].tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 3))

        app.buttons["Cancel"].tap()
        // Wait for the route detail to reappear — this confirms the sheet has fully
        // dismissed (including animation) before asserting the text field is gone.
        XCTAssertTrue(app.buttons["Create Quest"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.textFields.firstMatch.exists)
    }

    // MARK: - Quests list

    func test_questsTab_withFixtureData_showsQuestName() {
        app.tabBars.buttons["Quests"].tap()
        XCTAssertTrue(app.staticTexts["Morning Loop Quest"].waitForExistence(timeout: 3))
    }

    func test_tapQuest_navigatesToQuestDetail() {
        app.tabBars.buttons["Quests"].tap()
        XCTAssertTrue(app.staticTexts["Morning Loop Quest"].waitForExistence(timeout: 3))
        app.staticTexts["Morning Loop Quest"].tap()
        // Quest detail should show a "Start AR Run" button
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'AR Run'"))
            .firstMatch.waitForExistence(timeout: 3))
    }

    // MARK: - Empty states (launch without fixture data)

    func test_routesTab_withoutData_showsEmptyState() {
        app.terminate()
        let emptyApp = XCUIApplication()
        emptyApp.launchEnvironment["UI_TESTING"] = "1"
        // No LOAD_FIXTURE_ROUTES
        emptyApp.launch()
        emptyApp.tabBars.buttons["Routes"].tap()
        XCTAssertTrue(emptyApp.staticTexts["No Routes Yet"].waitForExistence(timeout: 3))
        emptyApp.terminate()
    }

    func test_questsTab_withoutData_showsEmptyState() {
        app.terminate()
        let emptyApp = XCUIApplication()
        emptyApp.launchEnvironment["UI_TESTING"] = "1"
        emptyApp.launch()
        emptyApp.tabBars.buttons["Quests"].tap()
        XCTAssertTrue(emptyApp.staticTexts.matching(NSPredicate(format: "label CONTAINS 'No Quests'"))
            .firstMatch.waitForExistence(timeout: 3))
        emptyApp.terminate()
    }

    // MARK: - Delete

    func test_contextMenuDelete_route_removesFromList() {
        app.tabBars.buttons["Routes"].tap()
        XCTAssertTrue(app.staticTexts["Hill Climb"].waitForExistence(timeout: 3))

        app.staticTexts["Hill Climb"].press(forDuration: 1.5)
        XCTAssertTrue(app.buttons["Delete Route"].waitForExistence(timeout: 3))
        app.buttons["Delete Route"].tap()

        // Confirm the deletion alert
        XCTAssertTrue(app.alerts["Delete Route?"].waitForExistence(timeout: 3))
        app.alerts["Delete Route?"].buttons["Delete"].tap()

        XCTAssertFalse(app.staticTexts["Hill Climb"].waitForExistence(timeout: 2))
    }
}
