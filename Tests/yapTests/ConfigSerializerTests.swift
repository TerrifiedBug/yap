import Foundation
import XCTest

@testable import yap

/// `Config.serialized(_:)` is the only thing that writes the config file for
/// the Settings window, so what it must never do is lose anything: a key it
/// has never heard of, a nested key, or a value type it does not model.
///
/// The pure function only. `Config.update` writes the real
/// `~/.config/yap/config.json`, which no test may touch.
final class ConfigSerializerTests: XCTestCase {
    private func parse(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTemplateRoundTripsWithTemplateKeyOrder() throws {
        let original = try parse(Config.template)
        let text = Config.serialized(original)

        XCTAssertEqual(
            NSDictionary(dictionary: try parse(text)),
            NSDictionary(dictionary: original)
        )

        let order = ["recordings_dir", "transcription", "mic_voice_processing",
                     "meeting_detection", "meeting_auto_record", "meeting_excluded_apps",
                     "dictation"]
        let offsets = order.map { text.range(of: "\"\($0)\"")?.lowerBound }
        XCTAssertFalse(offsets.contains(where: { $0 == nil }), "every template key is written")
        XCTAssertEqual(offsets.compactMap { $0 }, offsets.compactMap { $0 }.sorted())
    }

    func testUnknownKeysSurviveAtBothLevels() throws {
        var config = try parse(Config.template)
        config["custom"] = true
        config["custom_list"] = ["a", 2] as [Any]
        var dictation = try XCTUnwrap(config["dictation"] as? [String: Any])
        dictation["custom_nested"] = "kept"
        config["dictation"] = dictation

        let round = try parse(Config.serialized(config))
        XCTAssertEqual(NSDictionary(dictionary: round), NSDictionary(dictionary: config))
        XCTAssertEqual(
            (round["dictation"] as? [String: Any])?["custom_nested"] as? String, "kept")
    }

    func testExcludedAppsRoundTripAsAList() throws {
        var config = try parse(Config.template)
        config["meeting_excluded_apps"] = ["com.apple.PhotoBooth", "us.zoom.xos"]

        let round = try parse(Config.serialized(config))
        XCTAssertEqual(
            round["meeting_excluded_apps"] as? [String],
            ["com.apple.PhotoBooth", "us.zoom.xos"]
        )
    }
}
