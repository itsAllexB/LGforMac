import Foundation

/// Polls once per ~20s and applies any enabled schedule whose time matches the current
/// minute, exactly once per occurrence. Applies the target brightness to all TVs.
///
/// The minute-match means a schedule whose time passes while the timer isn't ticking —
/// Mac asleep — would silently never fire. So each tick also watches for a gap since the
/// previous tick, and applies the schedule that should be in effect after one. (If the
/// TVs are still off at that moment, TvController holds the value and delivers it when
/// they come back.)
final class ScheduleService {
    // Ticks are 20s apart; anything much longer means the process was suspended.
    private static let gapThreshold: TimeInterval = 90

    /// The current schedule list (called on the main thread).
    var getSchedules: () -> [BrightnessSchedule] = { [] }
    /// The brightness that should currently be in effect, per AppState's wrap-around rule.
    var getCurrentScheduledBrightness: () -> Int? = { nil }
    /// Applies a brightness to every TV (called on the main thread).
    var applyBrightnessAll: (Int) -> Void = { _ in }
    /// Raised after a schedule applies its brightness (value in %), for the OSD.
    var onScheduleApplied: ((Int) -> Void)?

    private var timer: Timer?
    private var minuteKey = ""
    private var firedThisMinute = Set<Int>()
    private var lastTick: Date?

    func start() {
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        let now = Date()

        let previousTick = lastTick
        lastTick = now
        if let previous = previousTick, now.timeIntervalSince(previous) > Self.gapThreshold,
           anyScheduleFires(between: previous, and: now) {
            Log.write("schedule: catching up after a \(Int(now.timeIntervalSince(previous) / 60)) min gap (Mac was asleep)")
            if let value = getCurrentScheduledBrightness() {
                applyBrightnessAll(value)
                onScheduleApplied?(value)
            }
        }

        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let key = "\(calendar.component(.year, from: now))-\(calendar.component(.month, from: now))-\(calendar.component(.day, from: now)) \(hour):\(minute)"
        if key != minuteKey {
            minuteKey = key
            firedThisMinute.removeAll()
        }

        let schedules = getSchedules()
        for (index, schedule) in schedules.enumerated() {
            if schedule.enabled && schedule.hour == hour && schedule.minute == minute
                && firedThisMinute.insert(index).inserted {
                applyBrightnessAll(schedule.brightness)
                onScheduleApplied?(schedule.brightness)
                Log.write(String(format: "schedule %02d:%02d fired -> %d%%",
                                 schedule.hour, schedule.minute, schedule.brightness))
            }
        }
    }

    // True when at least one enabled schedule's daily time falls inside (from, to] —
    // i.e. it would have fired during that window had the Mac been awake.
    private func anyScheduleFires(between from: Date, and to: Date) -> Bool {
        let enabled = getSchedules().filter(\.enabled)
        if enabled.isEmpty { return false }
        if to.timeIntervalSince(from) >= 86_400 { return true } // slept a day+ — every schedule passed

        let calendar = Calendar.current
        for schedule in enabled {
            // First occurrence of this schedule's time strictly after `from`.
            var occurrence = calendar.date(bySettingHour: schedule.hour, minute: schedule.minute,
                                           second: 0, of: from) ?? from
            if occurrence <= from {
                occurrence = calendar.date(byAdding: .day, value: 1, to: occurrence) ?? occurrence
            }
            if occurrence <= to { return true }
        }
        return false
    }

    func dispose() {
        timer?.invalidate()
        timer = nil
    }
}
