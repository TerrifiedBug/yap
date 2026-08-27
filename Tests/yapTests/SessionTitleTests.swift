import Foundation
import XCTest

@testable import yap

@MainActor
final class SessionTitleTests: XCTestCase {
    func testApplyTitleRenamesAndStamps() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("2026.08.27-1030", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = try JSONSerialization.data(withJSONObject: [
            "files": ["mic": "mic.caf"]
        ])
        try meta.write(to: dir.appendingPathComponent("meta.json"))
        try "# 2026.08.27-1030\n\nbody".write(
            to: dir.appendingPathComponent("transcript.md"),
            atomically: true,
            encoding: .utf8
        )

        let titled = RecordingSession.applyTitle("Weekly Sync: Q3/Planning", to: dir)
        XCTAssertEqual(
            titled.lastPathComponent,
            "2026.08.27-1030-Weekly Sync- Q3-Planning"
        )
        let updatedMeta = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: titled.appendingPathComponent("meta.json"))
            ) as? [String: Any]
        )
        XCTAssertEqual(updatedMeta["title"] as? String, "Weekly Sync: Q3/Planning")
        let transcript = try String(
            contentsOf: titled.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertEqual(
            transcript.components(separatedBy: "\n").first,
            "# 2026.08.27-1030-Weekly Sync- Q3-Planning"
        )

        let renamed = RecordingSession.applyTitle("Standup", to: titled)
        XCTAssertEqual(renamed.lastPathComponent, "2026.08.27-1030-Standup")
    }

    func testApplyTitleEmptyAfterSanitizeIsNoop() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("2026.08.27-1030", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let metaURL = dir.appendingPathComponent("meta.json")
        let meta = Data(#"{"files":{"mic":"mic.caf"}}"#.utf8)
        try meta.write(to: metaURL)

        XCTAssertEqual(RecordingSession.applyTitle("///", to: dir), dir)
        XCTAssertEqual(try Data(contentsOf: metaURL), meta)
    }
}
