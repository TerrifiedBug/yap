import Foundation

/// Keeping `~/.config/yap/config.json` current with the settings this build
/// has, which is a different job from reading values out of it.
///
/// A config written by an older yap has no line for anything added since, so
/// "Open Config File" opens a file that hides half the settings and the only
/// way to discover `tap_to_toggle` is the Settings window or the README. The
/// template every new install gets lists them all; this brings an existing
/// file up to the same standard.
extension Config {
    /// Add the keys this build knows about that the file on disk does not.
    ///
    /// The missing defaults and nothing else: values you have set are
    /// untouched, keys yap has never heard of are left alone, and the file
    /// keeps its own formatting, because a file someone hand-edited is not
    /// ours to tidy.
    ///
    /// Which is also why it gives up rather than force it. A section written
    /// on one line has nowhere to put a line, and splicing one in turns a tidy
    /// hand-written config into a mess that happens to parse; those keep their
    /// formatting and their missing keys, and the README stays the way to find
    /// them.
    ///
    /// Every rewrite is checked before it lands: the new text has to parse,
    /// and it has to differ from what was there by exactly the defaults being
    /// added. Anything else and the file is left alone — losing someone's
    /// config to a clever edit is far worse than an out-of-date one.
    static func ensureEveryKeyPresent() {
        guard
            let text = try? String(contentsOf: path, encoding: .utf8),
            let current = parse(text),
            let defaults = parse(template)
        else { return }

        let inner = missingFromDictation(current, defaults)
        let outer = missingAtTopLevel(current, defaults)
        guard !inner.isEmpty || !outer.isEmpty else { return }

        guard
            let updated = backfilled(text, inner: inner, outer: outer, defaults: defaults),
            let parsed = parse(updated),
            NSDictionary(dictionary: parsed).isEqual(
                to: expected(current, inner: inner, outer: outer, defaults: defaults))
        else { return }

        do {
            try updated.write(to: path, atomically: true, encoding: .utf8)
        } catch {
            warn("warning: could not update \(path.path): \(error)")
        }
    }

    // MARK: - what is missing

    /// A missing `dictation` object arrives as a whole missing top-level key,
    /// so this only has work to do when the section is already there.
    private static func missingFromDictation(
        _ current: [String: Any], _ defaults: [String: Any]
    ) -> [String] {
        guard
            let section = current["dictation"] as? [String: Any],
            let defaultSection = defaults["dictation"] as? [String: Any]
        else { return [] }
        return inTemplateOrder(defaultSection.keys.filter { section[$0] == nil })
    }

    private static func missingAtTopLevel(
        _ current: [String: Any], _ defaults: [String: Any]
    ) -> [String] {
        inTemplateOrder(defaults.keys.filter { current[$0] == nil })
    }

    /// The keys in the order the template lists them, so an inserted line
    /// reads where the documented file would have put it rather than wherever
    /// the alphabet lands. Shared with `Config.serialized(_:)`, which owes the
    /// GUI-written file the same order.
    ///
    /// Keys the template does not list share one position and are broken apart
    /// by name — a total order, so rewriting the file twice cannot shuffle
    /// somebody's hand-added keys around.
    static func inTemplateOrder(_ keys: some Collection<String>) -> [String] {
        func position(_ key: String) -> String.Index {
            template.range(of: "\"\(key)\"")?.lowerBound ?? template.endIndex
        }
        return keys.sorted {
            position($0) == position($1) ? $0 < $1 : position($0) < position($1)
        }
    }

    // MARK: - the edit, and what it has to produce

    /// Nested section first: inserting inside `dictation` leaves the file's own
    /// opening brace where it was, while inserting at the top level moves every
    /// offset after it — including the one just computed.
    private static func backfilled(
        _ text: String, inner: [String], outer: [String], defaults: [String: Any]
    ) -> String? {
        var updated = text
        if !inner.isEmpty {
            guard
                let step = insert(
                    inner, from: defaults["dictation"] as? [String: Any] ?? [:],
                    into: updated, after: "\"dictation\"", indent: "    ")
            else { return nil }
            updated = step
        }
        if !outer.isEmpty {
            guard let step = insert(outer, from: defaults, into: updated, indent: "  ")
            else { return nil }
            updated = step
        }
        return updated
    }

    /// What the file must parse to afterwards, so a rewrite that changed
    /// anything else never reaches the disk.
    private static func expected(
        _ current: [String: Any], inner: [String], outer: [String], defaults: [String: Any]
    ) -> [String: Any] {
        var result = current
        for key in outer { result[key] = defaults[key] }
        if var section = current["dictation"] as? [String: Any], !inner.isEmpty {
            for key in inner { section[key] = (defaults["dictation"] as? [String: Any])?[key] }
            result["dictation"] = section
        }
        return result
    }

    /// Put `"key": default` lines just inside the brace that opens an object —
    /// the one after `marker`, or the file's own when there is no marker.
    ///
    /// Text rather than a re-serialize, so nothing but the new lines moves.
    /// Nil when that brace does not end a line, which is the compact-file case
    /// this deliberately declines.
    private static func insert(
        _ keys: [String],
        from defaults: [String: Any],
        into text: String,
        after marker: String? = nil,
        indent: String
    ) -> String? {
        var searchFrom = text.startIndex
        if let marker {
            guard let found = text.range(of: marker) else { return nil }
            searchFrom = found.upperBound
        }
        guard
            let brace = text.range(of: "{", range: searchFrom..<text.endIndex),
            text[brace.upperBound...].first == "\n"
        else { return nil }

        var lines = ""
        for key in keys {
            guard let value = defaults[key], let literal = literal(value, indent: indent) else {
                return nil
            }
            lines += "\n\(indent)\"\(key)\": \(literal),"
        }
        return text.replacingCharacters(in: brace, with: "{\(lines)")
    }

    /// One JSON value as it would be written in the file. An object is spread
    /// over lines at the caller's indent, the way the template writes
    /// `dictation`; anything else is a single token.
    private static func literal(_ value: Any, indent: String) -> String? {
        // An object being written for the first time may as well have a stable
        // key order; a scalar has nothing to sort.
        let pretty = value is [String: Any]
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
        if pretty { options.formUnion([.prettyPrinted, .sortedKeys]) }
        guard
            let data = try? JSONSerialization.data(withJSONObject: value, options: options),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        guard pretty else { return text }
        // Two cosmetic fixes to Foundation's pretty printer, so a section it
        // writes reads like the template beside it rather than like output:
        // it puts a space before every colon, and it starts every line at
        // column zero regardless of where the key sits. Neither can corrupt
        // anything — the caller parses the result and compares it against the
        // values that went in before any of it reaches the disk.
        return text.replacingOccurrences(of: "\" : ", with: "\": ")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .joined(separator: "\n\(indent)")
    }

    private static func parse(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
