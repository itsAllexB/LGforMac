import Foundation

/// Loads and saves the TV list (incl. client-keys) plus app settings as JSON in
/// ~/Library/Application Support/LGforMac. Client-key reuse avoids re-pairing every launch.
final class DeviceStore {
    static let directory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LGforMac")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let devicesURL = directory.appendingPathComponent("devices.json")
    private let settingsURL = directory.appendingPathComponent("settings.json")

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    func loadDevices() -> [TvDevice] {
        guard let data = try? Data(contentsOf: devicesURL) else { return [] }
        return (try? JSONDecoder().decode([TvDevice].self, from: data)) ?? []
    }

    func saveDevices(_ devices: [TvDevice]) {
        if let data = try? Self.encoder().encode(devices) {
            try? data.write(to: devicesURL, options: .atomic)
        }
    }

    func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL) else { return AppSettings() }
        return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    func saveSettings(_ settings: AppSettings) {
        if let data = try? Self.encoder().encode(settings) {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }

    /// Serializes the full configuration (TVs + settings) to a single JSON backup string.
    func serializeBackup(devices: [TvDevice], settings: AppSettings) -> String {
        let backup = BackupData(devices: devices, settings: settings)
        guard let data = try? Self.encoder().encode(backup) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Parses a backup string; throws if the file isn't a valid LGforWin/LGforMac backup.
    func deserializeBackup(_ json: String) throws -> BackupData {
        var data = try JSONDecoder().decode(BackupData.self, from: Data(json.utf8))
        data.devices = data.devices ?? []
        data.settings = data.settings ?? AppSettings()
        return data
    }
}

/// Tiny append-only logger to ~/Library/Application Support/LGforMac/log.txt.
enum Log {
    private static let gate = NSLock()
    private static let url = DeviceStore.directory.appendingPathComponent("log.txt")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        gate.lock()
        defer { gate.unlock() }
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        // Keep the log small: reset if it grows past ~256 KB.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 256 * 1024 {
            try? Data().write(to: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
