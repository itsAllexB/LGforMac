import AppKit

/// Surfaces the macOS power lifecycle as callbacks: system sleep/wake, the displays
/// sleeping/waking (idle timer), and the session ending (shutdown / restart / log out).
/// All callbacks arrive on the main thread.
final class PowerEventService {
    /// The Mac is about to sleep. Handlers get a moment — send fast, synchronously.
    var onSuspending: (() -> Void)?
    /// The Mac woke from sleep.
    var onResumed: (() -> Void)?
    /// macOS turned the displays off (idle timeout) / back on. True = on.
    var onDisplayStateChanged: ((Bool) -> Void)?
    /// The session is ending: shutdown, restart or log out. Handlers get a few seconds.
    var onSessionEnding: (() -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var lastDisplayOn = true // only raise transitions

    init() {
        let center = NSWorkspace.shared.notificationCenter

        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Log.write("power: suspending")
            self?.onSuspending?()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Log.write("power: resumed")
            self?.onResumed?()
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.displayStateChanged(on: false)
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.displayStateChanged(on: true)
        })
        observers.append(center.addObserver(forName: NSWorkspace.willPowerOffNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Log.write("power: session ending")
            self?.onSessionEnding?()
        })
    }

    private func displayStateChanged(on: Bool) {
        guard on != lastDisplayOn else { return }
        lastDisplayOn = on
        Log.write("power: displays \(on ? "on" : "off")")
        onDisplayStateChanged?(on)
    }

    func dispose() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
    }
}
