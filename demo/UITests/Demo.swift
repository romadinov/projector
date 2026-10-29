import XCTest

let durations: [String: Double] = ["s01_open": 9.24, "s02_wbs": 13.7, "s03_critical": 11.8, "s04_start_after": 15.09, "s05_deadline": 10.54, "s06_slip": 5.25, "s07_late": 10.08, "s08_fix": 3.44, "s09_resources": 11.66, "s10_level": 14.49, "s11_quick": 15.05, "s12_preview": 14.21, "s13_apply": 9.85]

final class Demo: XCTestCase {
    var app: XCUIApplication!

    @MainActor func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    /// Runs a scene and holds it until its narration (+0.8 s) has played.
    @MainActor func scene(_ id: String, _ action: () throws -> Void) rethrows {
        let start = Date()
        print(String(format: "SCENE %@ %.3f", id, start.timeIntervalSince1970))
        try action()
        let end = start.addingTimeInterval(durations[id]! + 0.8)
        let wait = end.timeIntervalSinceNow
        if wait > 0 { Thread.sleep(forTimeInterval: wait) } else { print("OVERRUN \(id) \(-wait)") }
    }

    @MainActor func replaceText(in field: XCUIElement, with text: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10) + text + "\n")
    }

    @MainActor func testDemo() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication(bundleIdentifier: "com.ideahelix.projector")
        app.terminate()
        app.launch()
        sleep(4)
        print(String(format: "READY %.3f", Date().timeIntervalSince1970))

        scene("s01_open") {
            Thread.sleep(forTimeInterval: 4)
            point(863, 309).tap()
            XCTAssert(app.textFields["Kickoff"].waitForExistence(timeout: 10) || app.staticTexts["Kickoff"].exists)
        }
        scene("s02_wbs") {
            Thread.sleep(forTimeInterval: 7)
            app.buttons["Zoom Out"].tap()
            Thread.sleep(forTimeInterval: 0.6)
            app.buttons["Zoom Out"].tap()
        }
        scene("s03_critical") {
            Thread.sleep(forTimeInterval: 3)
            app.staticTexts["Tue, 10 Nov"].firstMatch.tap()      // Visual design, on the critical path
        }
        scene("s04_start_after") {
            app.staticTexts["Thu, 19 Nov"].firstMatch.tap()      // CMS integration
            Thread.sleep(forTimeInterval: 6)
            app.buttons["Inspector"].tap()
        }
        scene("s05_deadline") {
            app.staticTexts["Mon, 2 Nov"].firstMatch.tap()       // Design phase
        }
        scene("s06_slip") {
            app.buttons["Inspector"].tap()
            Thread.sleep(forTimeInterval: 1)
            replaceText(in: app.textFields["6 days"].firstMatch, with: "9d")
        }
        scene("s07_late") {
            Thread.sleep(forTimeInterval: 4)
            app.staticTexts["Mon, 2 Nov"].firstMatch.tap()
        }
        scene("s08_fix") {
            replaceText(in: app.textFields["9 days"].firstMatch, with: "6d")
        }
        scene("s09_resources") {
            app.buttons["Gantt"].firstMatch.tap()
            app.buttons["Resource Plan"].firstMatch.tap()
        }
        scene("s10_level") {
            Thread.sleep(forTimeInterval: 1)
            app.buttons.matching(NSPredicate(format: "label CONTAINS 'overallocated'")).firstMatch.tap()
        }
        scene("s11_quick") {
            app.buttons["BackButton"].firstMatch.tap()
            Thread.sleep(forTimeInterval: 1.5)
            point(502, 309).tap()
            XCTAssert(app.buttons["Quick Plan"].waitForExistence(timeout: 10))
            Thread.sleep(forTimeInterval: 0.5)
            app.buttons["Quick Plan"].tap()
            let editor = app.textViews.firstMatch
            XCTAssert(editor.waitForExistence(timeout: 5))
            editor.tap()
            editor.typeText("Kitchen refit\n  Design 1w @Ava\n  Permits 2w after Design\n  Demolition 3d after Permits, 2026-11-23 @Sam\n")
        }
        scene("s12_preview") {
            let editor = app.textViews.firstMatch
            editor.typeText("  Plumbing 4d after Demolition @Sam\n  Electrics 3d after Demolition @Ava\n  Cabinets 5d after Plumbing, Electrics @Sam\n  Handover 0d after Cabinets by 2026-12-04")
            let hide = app.keyboards.buttons["Hide keyboard"]
            if hide.exists { hide.tap() } else { point(683, 700).tap() }
        }
        scene("s13_apply") {
            app.buttons["Apply"].firstMatch.tap()
            Thread.sleep(forTimeInterval: 3)
            app.buttons["Zoom Out"].tap()
            Thread.sleep(forTimeInterval: 0.6)
            app.buttons["Zoom Out"].tap()
        }
        print(String(format: "END %.3f", Date().timeIntervalSince1970))
    }
}
