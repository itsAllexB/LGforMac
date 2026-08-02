import AppKit

/// A connected display, identified by a stable id and its friendly name.
struct ScreenInfo: Identifiable, Hashable {
    /// Stable identifier (the display's hardware UUID). Survives reboots, cable swaps
    /// and display reshuffles — persist THIS, not an index or CGDirectDisplayID.
    let id: String
    /// Friendly name, e.g. "LG TV SSCR2".
    let name: String
}

/// Enumerates connected displays with stable ids so a TV can be paired to the exact
/// screen it drives, and resolves a stored id back to an NSScreen for placing the OSD.
enum ScreenService {
    /// Lists the currently connected displays. Empty on failure (never throws).
    static func list() -> [ScreenInfo] {
        NSScreen.screens.compactMap { screen in
            guard let id = stableId(for: screen) else { return nil }
            return ScreenInfo(id: id, name: screen.localizedName)
        }
    }

    /// The NSScreen with the given stable id, or nil if it isn't connected.
    static func screen(withId id: String?) -> NSScreen? {
        guard let id, !id.isEmpty else { return nil }
        return NSScreen.screens.first { stableId(for: $0) == id }
    }

    /// Stable id of the display the mouse cursor is currently on, or nil if unknown.
    static func screenIdAtCursor() -> String? {
        screenAtCursor().flatMap(stableId(for:))
    }

    /// The screen under the mouse cursor (falls back to the main screen).
    static func screenAtCursor() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
    }

    /// Hardware UUID string for a screen — the macOS analogue of the EDID device path
    /// LGforWin persists on Windows.
    static func stableId(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            // Fall back to vendor/model/serial — still stable across launches.
            return "display-\(CGDisplayVendorNumber(displayID))-\(CGDisplayModelNumber(displayID))-\(CGDisplaySerialNumber(displayID))"
        }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
