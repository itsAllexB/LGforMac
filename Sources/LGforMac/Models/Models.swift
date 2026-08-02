import Foundation

/// Persisted description of a single LG webOS TV plus its last-known state.
/// JSON keys match LGforWin's `devices.json` exactly, so backups made on Windows
/// import here unchanged (client keys are bearer tokens — pairing carries over).
final class TvDevice: Codable, Identifiable {
    var name: String = "LG TV"
    var host: String = ""
    /// Pairing key returned by the TV on first accept; reused so the prompt never reappears.
    var clientKey: String = ""
    /// Last OLED Light (backlight) value 0-100 we set, for UI restore.
    var lastBacklight: Int = 80
    /// Stable id (display UUID) of the screen this TV drives, for cursor-targeted hotkeys and the OSD.
    var pairedScreenId: String = ""
    /// True once a secure wss://:3001 connection succeeded (2022+ models); tried first on reconnect.
    var secure: Bool = false
    /// MAC address learned via ARP while reachable, needed for Wake-on-LAN once the TV is off.
    var macAddress: String = ""

    let id = UUID()

    init(name: String = "LG TV", host: String = "") {
        self.name = name
        self.host = host
    }

    enum CodingKeys: String, CodingKey {
        case name = "Name", host = "Host", clientKey = "ClientKey"
        case lastBacklight = "LastBacklight", pairedScreenId = "PairedScreenId"
        case secure = "Secure", macAddress = "MacAddress"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "LG TV"
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        clientKey = try c.decodeIfPresent(String.self, forKey: .clientKey) ?? ""
        lastBacklight = try c.decodeIfPresent(Int.self, forKey: .lastBacklight) ?? 80
        pairedScreenId = try c.decodeIfPresent(String.self, forKey: .pairedScreenId) ?? ""
        secure = try c.decodeIfPresent(Bool.self, forKey: .secure) ?? false
        macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(clientKey, forKey: .clientKey)
        try c.encode(lastBacklight, forKey: .lastBacklight)
        try c.encode(pairedScreenId, forKey: .pairedScreenId)
        try c.encode(secure, forKey: .secure)
        try c.encode(macAddress, forKey: .macAddress)
    }
}

/// A time-of-day rule: at Hour:Minute set every TV's OLED Light to Brightness. Fires daily.
struct BrightnessSchedule: Codable, Identifiable, Equatable {
    var hour: Int = 8
    var minute: Int = 0
    var brightness: Int = 50
    var enabled: Bool = true

    var id = UUID()

    enum CodingKeys: String, CodingKey {
        case hour = "Hour", minute = "Minute", brightness = "Brightness", enabled = "Enabled"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? 8
        minute = try c.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        brightness = try c.decodeIfPresent(Int.self, forKey: .brightness) ?? 50
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hour, forKey: .hour)
        try c.encode(minute, forKey: .minute)
        try c.encode(brightness, forKey: .brightness)
        try c.encode(enabled, forKey: .enabled)
    }

    var minutesOfDay: Int { hour * 60 + minute }
}

/// Preferences for the on-screen display shown when brightness changes via hotkeys.
struct OsdSettings: Codable {
    var enabled: Bool = true
    /// Overlay style: 0 = macOS system pop-up (below the menu bar, like the native
    /// volume/brightness HUD — the default), 1 = Windows/LGforWin-style pill.
    var style: Int = 0
    /// Anchor for the Windows style: 0 bottom-centre, 1 bottom-left, 2 bottom-right,
    /// 3 top-centre, 4 top-left, 5 top-right. The macOS style always sits below the menu bar.
    var position: Int = 0
    /// Where to show: 0 = primary display, 1 = the adjusted TV's screen, 2 = screen under the cursor.
    var monitor: Int = 0
    var timeoutSeconds: Double = 1.6
    var showTvName: Bool = false
    var showOnSchedule: Bool = false

    enum CodingKeys: String, CodingKey {
        case enabled = "Enabled", style = "Style", position = "Position", monitor = "Monitor"
        case timeoutSeconds = "TimeoutSeconds", showTvName = "ShowTvName", showOnSchedule = "ShowOnSchedule"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        style = try c.decodeIfPresent(Int.self, forKey: .style) ?? 0
        position = try c.decodeIfPresent(Int.self, forKey: .position) ?? 0
        monitor = try c.decodeIfPresent(Int.self, forKey: .monitor) ?? 0
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 1.6
        showTvName = try c.decodeIfPresent(Bool.self, forKey: .showTvName) ?? false
        showOnSchedule = try c.decodeIfPresent(Bool.self, forKey: .showOnSchedule) ?? false
    }
}

/// Rules for automatically turning the TVs on and off with the Mac. All apply to every TV; opt-in.
struct PowerSettings: Codable {
    /// Wake the TVs (WoL) whenever the app starts — with launch-at-login, that's sign-in.
    var onAppStart: Bool = false
    /// Wake the TVs when the Mac wakes from sleep.
    var onResume: Bool = false
    /// Turn the TVs off when the Mac goes to sleep.
    var offOnSleep: Bool = false
    /// Turn the TVs off when the Mac shuts down, restarts or the user logs out.
    var offOnShutdown: Bool = false
    /// React when macOS puts the displays to sleep (idle timer).
    var followDisplayOff: Bool = false
    /// What followDisplayOff does: 0 = screen off (panel blanked, instant resume), 1 = full power off.
    var displayOffAction: Int = 0
    /// Wake the TVs when the displays wake back up.
    var followDisplayOn: Bool = false

    enum CodingKeys: String, CodingKey {
        case onAppStart = "OnAppStart", onResume = "OnResume", offOnSleep = "OffOnSleep"
        case offOnShutdown = "OffOnShutdown", followDisplayOff = "FollowDisplayOff"
        case displayOffAction = "DisplayOffAction", followDisplayOn = "FollowDisplayOn"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        onAppStart = try c.decodeIfPresent(Bool.self, forKey: .onAppStart) ?? false
        onResume = try c.decodeIfPresent(Bool.self, forKey: .onResume) ?? false
        offOnSleep = try c.decodeIfPresent(Bool.self, forKey: .offOnSleep) ?? false
        offOnShutdown = try c.decodeIfPresent(Bool.self, forKey: .offOnShutdown) ?? false
        followDisplayOff = try c.decodeIfPresent(Bool.self, forKey: .followDisplayOff) ?? false
        displayOffAction = try c.decodeIfPresent(Int.self, forKey: .displayOffAction) ?? 0
        followDisplayOn = try c.decodeIfPresent(Bool.self, forKey: .followDisplayOn) ?? false
    }
}

/// App-wide preferences. JSON keys match LGforWin's settings.json / backup format —
/// "StartWithWindows" is kept as the key for the launch-at-login flag for compatibility.
struct AppSettings: Codable {
    /// How many points the brightness hotkeys nudge per press (1–25).
    var hotkeyStep: Int = 10
    /// Modifier bitmask: 1 = Option (Alt), 2 = Control (Ctrl), 4 = Shift, 8 = Command (Win).
    /// Same values as LGforWin's MOD_* mask. Default Control+Option (3).
    var hotkeyModifiers: Int = 3
    var startAtLogin: Bool = false
    /// How the window opens on an autostart launch: 0 = normal, 1 = minimized, 2 = menu bar only.
    var launchBehavior: Int = 0
    var themeIndex: Int = 0
    var schedules: [BrightnessSchedule] = []
    var applyScheduleOnStartup: Bool = false
    var osd = OsdSettings()
    var power = PowerSettings()

    enum CodingKeys: String, CodingKey {
        case hotkeyStep = "HotkeyStep", hotkeyModifiers = "HotkeyModifiers"
        case startAtLogin = "StartWithWindows", launchBehavior = "LaunchBehavior"
        case themeIndex = "ThemeIndex", schedules = "Schedules"
        case applyScheduleOnStartup = "ApplyScheduleOnStartup"
        case osd = "Osd", power = "Power"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkeyStep = try c.decodeIfPresent(Int.self, forKey: .hotkeyStep) ?? 10
        hotkeyModifiers = try c.decodeIfPresent(Int.self, forKey: .hotkeyModifiers) ?? 3
        startAtLogin = try c.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? false
        launchBehavior = try c.decodeIfPresent(Int.self, forKey: .launchBehavior) ?? 0
        themeIndex = try c.decodeIfPresent(Int.self, forKey: .themeIndex) ?? 0
        schedules = try c.decodeIfPresent([BrightnessSchedule].self, forKey: .schedules) ?? []
        applyScheduleOnStartup = try c.decodeIfPresent(Bool.self, forKey: .applyScheduleOnStartup) ?? false
        osd = try c.decodeIfPresent(OsdSettings.self, forKey: .osd) ?? OsdSettings()
        power = try c.decodeIfPresent(PowerSettings.self, forKey: .power) ?? PowerSettings()
    }
}

/// A single-file backup bundling all TVs and app settings (LGforWin-compatible).
struct BackupData: Codable {
    var devices: [TvDevice]?
    var settings: AppSettings?

    enum CodingKeys: String, CodingKey {
        case devices = "Devices", settings = "Settings"
    }
}
