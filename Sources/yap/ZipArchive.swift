import Compression
import Foundation

/// Just enough of the zip format to unpack a signed .app, in process.
///
/// Foundation has no unarchiver, so the obvious move is to shell out to
/// `ditto`. yap does not spawn processes, so this reads the archive itself:
/// the central directory, then each entry, inflating with the Compression
/// framework. It is about as much of the format as `ditto -c -k` can produce
/// and no more — stored and deflated entries, directories, symlinks, POSIX
/// modes — and it refuses anything else rather than guessing.
///
/// What it deliberately drops is the AppleDouble sidecars (`._name`,
/// `__MACOSX/`) that carry extended attributes and resource forks. Nothing in
/// a yap release needs them: `build-release.sh` runs `xattr -cr` before
/// signing, and an extraction with them discarded verifies `valid on disk` and
/// `satisfies its Designated Requirement` — checked against a real
/// Developer ID-signed bundle, because a bundle that unpacks subtly wrong
/// would fail `SecStaticCodeCheckValidity` in `Updater.verify` and leave the
/// user stuck on an old build with no explanation.
///
/// No CRC check. The updater has already matched a SHA-256 over the whole
/// archive before it gets here, and verifies the signature of what comes out
/// afterwards; a per-entry CRC sits between two stronger checks.
enum ZipArchive {
    enum ZipError: LocalizedError {
        case notAZip
        case unsupported(String)
        case truncated
        case escapingPath(String)

        var errorDescription: String? {
            switch self {
            case .notAZip: return "not a zip archive"
            case .unsupported(let what): return "unsupported zip feature: \(what)"
            case .truncated: return "zip archive is truncated"
            case .escapingPath(let name): return "zip entry escapes the destination: \(name)"
            }
        }
    }

    /// Unpack `archive` into `destination`, which is created if missing.
    static func extract(_ archive: URL, to destination: URL) throws {
        let data = try Data(contentsOf: archive)
        let directory = try centralDirectory(in: data)
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true)

        for entry in directory {
            // AppleDouble sidecars. See the note on the type.
            let last = entry.name.split(separator: "/").last.map(String.init) ?? entry.name
            if entry.name.hasPrefix("__MACOSX/") || last.hasPrefix("._") { continue }

            let target = try resolve(entry.name, under: destination)
            if entry.name.hasSuffix("/") {
                try FileManager.default.createDirectory(
                    at: target, withIntermediateDirectories: true)
                continue
            }
            // Refused, not created, and this is the load-bearing line in the
            // file. The containment check above is lexical: an entry that
            // creates `staging/link -> /somewhere` makes every later entry
            // named `link/…` pass a text comparison while the write follows
            // the link out of the staging directory — before the signature is
            // checked, which is the one moment yap is holding bytes it does
            // not trust yet. Refusing the link removes the class rather than
            // racing it. Measured: a yap release contains no symlinks at all,
            // so this costs nothing today. It would start costing something
            // the day a release embeds a framework, and it should fail loudly
            // then rather than quietly grow a hole.
            if entry.mode & S_IFMT == S_IFLNK {
                throw ZipError.unsupported("symbolic link (\(entry.name))")
            }

            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let contents = try body(of: entry, in: data)
            // The executable bit is the one that matters: a Mach-O written
            // 0644 is a bundle macOS will not launch.
            let permissions = entry.mode & 0o7777
            guard
                FileManager.default.createFile(
                    atPath: target.path, contents: contents,
                    attributes: permissions == 0 ? nil : [.posixPermissions: permissions])
            else { throw ZipError.truncated }
        }
    }

    // MARK: - reading

    private struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        let mode: mode_t
    }

    /// Entry names are attacker-controlled the moment a feed is: an archive
    /// saying `../../bin/launchd` must not write there.
    ///
    /// The name is judged, not the joined path. The previous version compared
    /// two `standardizedFileURL` paths, which is a security check that depends
    /// on the filesystem and on Foundation's willingness to resolve the
    /// `/tmp` → `/private/tmp` class of symlink — and it does so
    /// asymmetrically: hand it a *relative* destination and an ordinary
    /// `yap.app/` entry is rejected as an escape. The updater only ever passes
    /// an absolute path, so nothing shipped was broken; a rule this important
    /// should not rest on that being true forever.
    ///
    /// Judging the components instead is symmetric, touches no filesystem, and
    /// says exactly what is meant: every written path is the destination plus
    /// a sequence of plain names. With symlink entries refused as well, that
    /// is the whole containment argument — nothing inside the destination can
    /// point outside it.
    private static func resolve(_ name: String, under destination: URL) throws -> URL {
        let components = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !name.hasPrefix("/"), !components.isEmpty,
            !components.contains(".."), !components.contains(".")
        else { throw ZipError.escapingPath(name) }
        return components.reduce(destination) { $0.appendingPathComponent($1) }
    }

    private static func centralDirectory(in data: Data) throws -> [Entry] {
        // The end-of-central-directory record is last, after a comment of up
        // to 64 KB, so it is found by scanning back for its signature.
        let eocdSignature: UInt32 = 0x0605_4B50
        let minimum = 22
        guard data.count >= minimum else { throw ZipError.notAZip }
        var eocd: Int?
        let earliest = max(0, data.count - minimum - 0xFFFF)
        var index = data.count - minimum
        while index >= earliest {
            if u32(data, index) == eocdSignature {
                eocd = index
                break
            }
            index -= 1
        }
        guard let eocd else { throw ZipError.notAZip }

        let count = Int(u16(data, eocd + 10))
        let start = Int(u32(data, eocd + 16))
        guard count != 0xFFFF, start != 0xFFFF_FFFF else {
            throw ZipError.unsupported("zip64")
        }

        var entries: [Entry] = []
        var cursor = start
        for _ in 0..<count {
            guard cursor + 46 <= data.count, u32(data, cursor) == 0x0201_4B50 else {
                throw ZipError.truncated
            }
            let method = u16(data, cursor + 10)
            let compressed = Int(u32(data, cursor + 20))
            let uncompressed = Int(u32(data, cursor + 24))
            let nameLength = Int(u16(data, cursor + 28))
            let extraLength = Int(u16(data, cursor + 30))
            let commentLength = Int(u16(data, cursor + 32))
            let external = u32(data, cursor + 38)
            let localOffset = Int(u32(data, cursor + 42))
            guard cursor + 46 + nameLength <= data.count else { throw ZipError.truncated }
            let name = String(
                decoding: data[(data.startIndex + cursor + 46)..<(data.startIndex + cursor + 46 + nameLength)],
                as: UTF8.self)
            guard compressed != 0xFFFF_FFFF, uncompressed != 0xFFFF_FFFF,
                localOffset != 0xFFFF_FFFF
            else { throw ZipError.unsupported("zip64") }

            entries.append(
                Entry(
                    name: name, method: method,
                    compressedSize: compressed, uncompressedSize: uncompressed,
                    localHeaderOffset: localOffset,
                    // The high 16 bits are the Unix mode, when the archive was
                    // made on a Unix host. Zero otherwise, which reads as
                    // "leave the default".
                    mode: mode_t(external >> 16)))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func body(of entry: Entry, in data: Data) throws -> Data {
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, u32(data, header) == 0x0403_4B50 else {
            throw ZipError.truncated
        }
        // The local header repeats the name and extra field, and its extra
        // field length can differ from the central one — so it is read here
        // rather than assumed.
        let nameLength = Int(u16(data, header + 26))
        let extraLength = Int(u16(data, header + 28))
        let start = header + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= data.count else { throw ZipError.truncated }
        let slice = data[(data.startIndex + start)..<(data.startIndex + start + entry.compressedSize)]

        switch entry.method {
        case 0:
            return Data(slice)
        case 8:
            guard entry.uncompressedSize > 0 else { return Data() }
            return try inflate(Data(slice), to: entry.uncompressedSize)
        default:
            throw ZipError.unsupported("compression method \(entry.method)")
        }
    }

    /// `COMPRESSION_ZLIB` is Apple's name for raw DEFLATE, which is what a zip
    /// entry holds — no zlib wrapper to strip.
    private static func inflate(_ compressed: Data, to size: Int) throws -> Data {
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            compressed.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                    let sourceBase = source.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(
                    destinationBase, size, sourceBase, compressed.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw ZipError.truncated }
        return output
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) | UInt32(data[base + 1]) << 8
            | UInt32(data[base + 2]) << 16 | UInt32(data[base + 3]) << 24
    }
}
