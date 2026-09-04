import AppKit
import XCTest

@testable import yap

/// The pill answers once.
///
/// It fades for 160 ms after a click and stays clickable for all of it, which
/// is long enough to double-click by accident — and the destructive action is
/// the one where that matters: the second `trashItem` finds the folder already
/// gone and reports a failure the user did not cause.
///
/// Driven through the real buttons rather than the private selectors, because
/// the window this guards is between the click and the fade, and only a real
/// `performClick` sits in it.
@MainActor
final class PromptPanelTests: XCTestCase {
    override func tearDown() {
        retirePrompt()
        for panel in NSApp.windows.compactMap({ $0 as? PromptPanel }) {
            panel.close()
        }
        super.tearDown()
    }

    private func button(_ title: String) throws -> NSButton {
        let panel = try XCTUnwrap(
            NSApp.windows.compactMap { $0 as? PromptPanel }.last, "no pill on screen")
        let match = Self.buttons(in: try XCTUnwrap(panel.contentView))
            .first { $0.attributedTitle.string == title }
        return try XCTUnwrap(match, "no \"\(title)\" button in the pill")
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { subview -> [NSButton] in
            (subview as? NSButton).map { [$0] } ?? buttons(in: subview)
        }
    }

    /// Two clicks inside the fade must produce one deletion.
    func testDestructiveActionRunsOnceUnderADoubleClick() throws {
        var deletions = 0
        showToast(
            title: "Transcript ready", body: "2026.01.01-0000", button: "Open",
            destructiveButton: "Delete", onDestructive: { deletions += 1 },
            onAccept: {}
        )

        let delete = try button("Delete")
        delete.performClick(nil)
        delete.performClick(nil)

        // Long enough for both fades to have finished if the second click had
        // started one.
        spinRunLoop(for: 0.6)
        XCTAssertEqual(deletions, 1)
    }

    /// The guard is the panel's, not the button's: clicking Delete and then
    /// Open must not do both.
    func testASecondButtonCannotAnswerAnAlreadyAnsweredPill() throws {
        var deletions = 0
        var opens = 0
        showToast(
            title: "Transcript ready", body: "2026.01.01-0000", button: "Open",
            destructiveButton: "Delete", onDestructive: { deletions += 1 },
            onAccept: { opens += 1 }
        )

        try button("Delete").performClick(nil)
        try button("Open").performClick(nil)

        spinRunLoop(for: 0.6)
        XCTAssertEqual(deletions, 1)
        XCTAssertEqual(opens, 0)
    }

    /// The ordinary single click still works — a guard that swallowed the
    /// first click would pass both tests above.
    func testASingleClickStillAnswers() throws {
        var opens = 0
        showToast(
            title: "Transcript ready", body: "2026.01.01-0000", button: "Open",
            onAccept: { opens += 1 }
        )

        try button("Open").performClick(nil)
        spinRunLoop(for: 0.6)
        XCTAssertEqual(opens, 1)
    }

    /// The fade's completion is delivered by the main run loop, so the test
    /// has to let it run rather than sleeping the thread it arrives on.
    private func spinRunLoop(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}
