import AppKit

/// The menu-bar mark — Lucide's `speech`, a head in profile with two sound
/// arcs, inlined as SVG. Keeping the artwork in source means the executable
/// has no separate resource bundle to install alongside it: true
/// single-binary.
///
/// It replaced a feather, which said "writing" rather than "talking" and was
/// too fine to hold its weight beside the system icons.
enum StatusIcon {
    /// Template image at `size` points, so callers can tint it.
    ///
    /// `badged` draws a filled dot at the bottom-right, for a staged update.
    /// Still a template: the dot inherits the menu bar's own colour, which is
    /// the only way a status item can raise its voice without looking like an
    /// error.
    static func image(size: CGFloat, badged: Bool = false) -> NSImage? {
        guard let data = svg.data(using: .utf8), let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        guard badged else { return image }

        let badge = (size * 0.34).rounded()
        let composed = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            let dot = NSRect(
                x: rect.maxX - badge, y: rect.minY, width: badge, height: badge)
            // Clear a slightly larger circle first, so the dot reads as
            // separate rather than as part of the head at 16 points.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            // Any opaque colour: a template image carries only its alpha.
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        composed.isTemplate = true
        return composed
    }

    /// Stroke 2, not the 1.5 the feather used: compared against the real menu
    /// bar, 1.5 reads spindly next to the battery and Wi-Fi outlines, and 2.5
    /// starts closing up the head and merging the two arcs. 2 is where the
    /// weight matches and the shapes stay open.
    private static let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M8.8 20v-4.1l1.9.2a2.3 2.3 0 0 0 2.164-2.1V8.3A5.37 5.37 0 0 0 2 8.25c0 2.8.656 3.054 1 4.55a5.77 5.77 0 0 1 .029 2.758L2 20"/>\
    <path d="M19.8 17.8a7.5 7.5 0 0 0 .003-10.603"/>\
    <path d="M17 15a3.5 3.5 0 0 0-.025-4.975"/>\
    </svg>
    """
}
