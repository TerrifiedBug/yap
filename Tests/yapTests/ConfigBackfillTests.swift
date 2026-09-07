import Foundation
import XCTest

@testable import yap

/// `Config.backfilled` splices lines for missing keys into the file's own
/// text. What it owes the reader is that a line lands where the template
/// lists it, and what it owes the file is that nothing else moves and the
/// result still parses to exactly the old values plus the defaults.
///
/// The pure function only. `ensureEveryKeyPresent` reads and writes the real
/// `~/.config/yap/config.json`, which no test may touch.
final class ConfigBackfillTests: XCTestCase {
    private func parse(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private var defaults: [String: Any] {
        get throws { try parse(Config.template) }
    }

    /// Lines of `text`, trimmed, so a test can say "this line, then that one".
    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func testMissingKeyLandsAfterItsTemplatePredecessor() throws {
        // A file written before recording_routes existed.
        let old = Config.template.replacingOccurrences(of: "  \"recording_routes\": {},\n", with: "")
        XCTAssertNil(old.range(of: "recording_routes"))

        let updated = try XCTUnwrap(
            Config.backfilled(old, inner: [], outer: ["recording_routes"], defaults: try defaults))

        let all = lines(updated)
        let dir = try XCTUnwrap(all.firstIndex { $0.hasPrefix("\"recordings_dir\"") })
        XCTAssertEqual(all[dir + 1], "\"recording_routes\": {},", "one line, one token, right under recordings_dir")
        XCTAssertEqual(NSDictionary(dictionary: try parse(updated)), NSDictionary(dictionary: try defaults))
    }

    func testTwoMissingNeighboursKeepTemplateOrder() throws {
        let old = Config.template
            .replacingOccurrences(of: "  \"recording_routes\": {},\n", with: "")
            .replacingOccurrences(of: "  \"transcription\": { \"enabled\": true },\n", with: "")

        let updated = try XCTUnwrap(
            Config.backfilled(
                old, inner: [], outer: ["recording_routes", "transcription"], defaults: try defaults))

        let all = lines(updated)
        let dir = try XCTUnwrap(all.firstIndex { $0.hasPrefix("\"recordings_dir\"") })
        XCTAssertTrue(all[dir + 1].hasPrefix("\"recording_routes\""))
        XCTAssertTrue(all[dir + 2].hasPrefix("\"transcription\""))
        XCTAssertEqual(NSDictionary(dictionary: try parse(updated)), NSDictionary(dictionary: try defaults))
    }

    func testNestedKeyLandsAfterItsPredecessorInsideTheSection() throws {
        let old = Config.template.replacingOccurrences(of: "    \"overlay\": true,\n", with: "")

        let updated = try XCTUnwrap(
            Config.backfilled(old, inner: ["overlay"], outer: [], defaults: try defaults))

        let all = lines(updated)
        let tap = try XCTUnwrap(all.firstIndex { $0.hasPrefix("\"tap_to_toggle\"") })
        XCTAssertEqual(all[tap + 1], "\"overlay\": true,")
        XCTAssertEqual(NSDictionary(dictionary: try parse(updated)), NSDictionary(dictionary: try defaults))
    }

    func testValueSpreadOverLinesIsNeverAnAnchor() throws {
        // `dictation` follows `meeting_excluded_apps` in the template, but the
        // array here continues past its own line (and closes without a comma),
        // so there is no edge under it to insert on. The line has to go under
        // the nearest single-line key instead, and the array must not move.
        let old = """
            {
              "recordings_dir": "~/Recordings",
              "meeting_auto_record": false,
              "meeting_excluded_apps": [
                "com.apple.PhotoBooth"
              ]
            }

            """
        let updated = try XCTUnwrap(
            Config.backfilled(old, inner: [], outer: ["dictation"], defaults: try defaults))

        let all = lines(updated)
        let auto = try XCTUnwrap(all.firstIndex { $0.hasPrefix("\"meeting_auto_record\"") })
        XCTAssertEqual(all[auto + 1], "\"dictation\": {")
        XCTAssertNotNil(
            updated.range(of: "  \"meeting_excluded_apps\": [\n    \"com.apple.PhotoBooth\"\n  ]\n}"))

        var expected = try parse(old)
        expected["dictation"] = try defaults["dictation"]
        XCTAssertEqual(NSDictionary(dictionary: try parse(updated)), NSDictionary(dictionary: expected))
    }
}
