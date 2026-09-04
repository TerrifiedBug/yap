import Foundation
import XCTest

@testable import yap

/// The updater unpacks a signed .app with this and then checks its signature,
/// so an extractor that is subtly wrong does not corrupt anything — it just
/// means updates silently never install. These pin the details that would go
/// wrong quietly: the executable bit, symlinks, both compression methods, and
/// the AppleDouble sidecars that must be dropped rather than written as files.
final class ZipArchiveTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/dev/null")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yap-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func unpackFixture() throws -> URL {
        let archive = directory.appendingPathComponent("fixture.zip")
        try XCTUnwrap(Data(base64Encoded: Self.fixture, options: .ignoreUnknownCharacters))
            .write(to: archive)
        let destination = directory.appendingPathComponent("out")
        try ZipArchive.extract(archive, to: destination)
        return destination
    }

    /// The containment rule must not depend on how the caller spelled the
    /// destination. The first version compared two standardized paths, which
    /// resolves symlinks off the filesystem and does it asymmetrically: with a
    /// relative destination it rejected an ordinary `yap.app/` entry. The
    /// updater always passes an absolute path, so nothing shipped was broken —
    /// this pins it so nothing has to keep being true by luck.
    func testDestinationSpellingDoesNotAffectExtraction() throws {
        let previous = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(previous) }
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(directory.path))

        let archive = directory.appendingPathComponent("fixture.zip")
        try XCTUnwrap(Data(base64Encoded: Self.fixture, options: .ignoreUnknownCharacters))
            .write(to: archive)

        // Relative, resolved against the working directory set above.
        try ZipArchive.extract(URL(fileURLWithPath: "fixture.zip"), to: URL(fileURLWithPath: "out"))
        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent("out/bundle/Info.plist"),
                encoding: .utf8),
            "<plist/>")
    }

    /// Deflated, and 0755: a Mach-O written 0644 is a bundle macOS refuses to
    /// launch, and nothing else in the update path would notice.
    func testDeflatedEntryKeepsItsContentsAndExecutableBit() throws {
        let out = try unpackFixture()
        let tool = out.appendingPathComponent("bundle/MacOS/tool")
        let contents = try String(contentsOf: tool, encoding: .utf8)
        XCTAssertEqual(contents, String(repeating: "#!/bin/sh\necho hello\n", count: 40))

        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: tool.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.int16Value, 0o755)
    }

    func testStoredEntryRoundTrips() throws {
        let out = try unpackFixture()
        let plist = out.appendingPathComponent("bundle/Info.plist")
        XCTAssertEqual(try String(contentsOf: plist, encoding: .utf8), "<plist/>")
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: plist.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.int16Value, 0o644)
    }

    /// A symlink entry is how the lexical containment check above is beaten:
    /// create `staging/link -> /somewhere`, then name a later entry
    /// `link/file`, and the write follows the link out of staging — before the
    /// signature has been checked. A yap release contains no symlinks, so they
    /// are refused rather than raced.
    func testSymlinkEntriesAreRefused() throws {
        let archive = directory.appendingPathComponent("link.zip")
        try XCTUnwrap(Data(base64Encoded: Self.symlinked, options: .ignoreUnknownCharacters))
            .write(to: archive)
        let destination = directory.appendingPathComponent("out")

        XCTAssertThrowsError(try ZipArchive.extract(archive, to: destination)) { error in
            guard case ZipArchive.ZipError.unsupported = error else {
                return XCTFail("expected an unsupported error, got \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("bundle/link").path))
    }

    /// Written as a file rather than dropped, `._Info.plist` would be a stray
    /// binary blob inside the bundle — one the signature does not account for.
    func testAppleDoubleSidecarsAreDropped() throws {
        let out = try unpackFixture()
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: out.appendingPathComponent("bundle/._Info.plist").path))
    }

    func testDirectoryEntriesAreCreated() throws {
        let out = try unpackFixture()
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: out.appendingPathComponent("bundle/Resources").path,
                isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    /// The feed is the attacker's lever if it is anyone's, so an entry naming
    /// its way out of the staging directory has to be refused, not written.
    func testEntriesCannotEscapeTheDestination() throws {
        let archive = directory.appendingPathComponent("evil.zip")
        try XCTUnwrap(Data(base64Encoded: Self.escaping, options: .ignoreUnknownCharacters))
            .write(to: archive)
        let destination = directory.appendingPathComponent("out")

        XCTAssertThrowsError(try ZipArchive.extract(archive, to: destination)) { error in
            guard case ZipArchive.ZipError.escapingPath = error else {
                return XCTFail("expected an escapingPath error, got \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("escaped.txt").path))
    }

    func testGarbageIsRejected() throws {
        let archive = directory.appendingPathComponent("junk.zip")
        try Data(repeating: 0x41, count: 512).write(to: archive)
        XCTAssertThrowsError(
            try ZipArchive.extract(archive, to: directory.appendingPathComponent("out")))
    }

    // MARK: - fixtures

    /// A deflated executable, a stored file, an AppleDouble sidecar and a
    /// directory entry — the shape `ditto -c -k` produces for an .app.
    private static let fixture = """
        UEsDBBQAAAAIAAAAIQBPy6xkIAAAAEgDAAARAAAAYnVuZGxlL01hY09TL3Rvb2xTVtRPyszTL87g
        Sk3OyFfISM3JyedSHhUcFRwVJEUQAFBLAwQUAAAAAAAAACEAVXkzSQgAAAAIAAAAEQAAAGJ1bmRs
        ZS9JbmZvLnBsaXN0PHBsaXN0Lz5QSwMEFAAAAAAAAAAhAH2OCncIAAAACAAAABMAAABidW5kbGUv
        Ll9JbmZvLnBsaXN0AAUWB2p1bmtQSwMEFAAAAAAAAAAhAAAAAAAAAAAAAAAAABEAAABidW5kbGUv
        UmVzb3VyY2VzL1BLAQIUAxQAAAAIAAAAIQBPy6xkIAAAAEgDAAARAAAAAAAAAAAAAADtgQAAAABi
        dW5kbGUvTWFjT1MvdG9vbFBLAQIUAxQAAAAAAAAAIQBVeTNJCAAAAAgAAAARAAAAAAAAAAAAAACk
        gU8AAABidW5kbGUvSW5mby5wbGlzdFBLAQIUAxQAAAAAAAAAIQB9jgp3CAAAAAgAAAATAAAAAAAA
        AAAAAACkgYYAAABidW5kbGUvLl9JbmZvLnBsaXN0UEsBAhQDFAAAAAAAAAAhAAAAAAAAAAAAAAAA
        ABEAAAAAAAAAAAAQAO1BvwAAAGJ1bmRsZS9SZXNvdXJjZXMvUEsFBgAAAAAEAAQA/gAAAO4AAAAA
        AA==
        """

    /// One entry, a symbolic link.
    private static let symlinked = """
        UEsDBBQAAAAAAAAAIQCv5eEIBAAAAAQAAAALAAAAYnVuZGxlL2xpbmsvZXRjUEsBAhQDFAAAAAAA
        AAAhAK/l4QgEAAAABAAAAAsAAAAAAAAAAAAAAO2hAAAAAGJ1bmRsZS9saW5rUEsFBgAAAAABAAEA
        OQAAAC0AAAAAAA==
        """

    /// One entry, named `../escaped.txt`.
    private static let escaping = """
        UEsDBBQAAAAAAAAAIQDjdvzOCAAAAAgAAAAOAAAALi4vZXNjYXBlZC50eHRlc2NhcGVkClBLAQIU
        AxQAAAAAAAAAIQDjdvzOCAAAAAgAAAAOAAAAAAAAAAAAAACkgQAAAAAuLi9lc2NhcGVkLnR4dFBL
        BQYAAAAAAQABADwAAAA0AAAAAAA=
        """
}
