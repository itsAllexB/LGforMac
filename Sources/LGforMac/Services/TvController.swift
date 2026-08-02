import Foundation

enum TvStatus {
    case disconnected, connecting, awaitingPairing, connected, error
}

/// High-level controller for one TV: owns the WebOSClient, drives the connect/pair
/// lifecycle with auto-reconnect, and exposes a debounced setBacklight so dragging the
/// slider doesn't flood the socket.
final class TvController {
    private static let debounceMs = 120
    /// Cap on a single SSAP request, so a dead-but-open socket can't hang a caller forever.
    private static let requestTimeout: TimeInterval = 3
    /// How many times, and how far apart, powerOn retries waking an unresponsive TV.
    private static let wakeAttempts = 4
    private static let wakeRetryDelay: TimeInterval = 3
    /// How often to prove the socket is still alive while connected.
    private static let heartbeatSeconds = 30

    let device: TvDevice
    private var client: WebOSClient?
    private var connectTask: Task<Void, Never>?

    private let gate = NSLock()
    private let debounceQueue = DispatchQueue(label: "LGforMac.TvController.debounce")
    private var debounceItem: DispatchWorkItem?
    private var pendingValue = 0
    private var hasPending = false
    private var disposed = false

    // A brightness value that couldn't be delivered because the TV was off or unreachable
    // (typically a schedule firing while the panel sleeps). Pushed as soon as the TV is
    // back — on reconnect, or on a standby→awake transition over a still-open socket.
    private var missedWhileOff: Int?

    private var lastPowerState: String?
    private var startupApplied = false

    private(set) var status: TvStatus = .disconnected

    /// Optional: returns the brightness to apply once, on the first successful connect this
    /// session (schedule catch-up). Return nil to skip.
    var getStartupBrightness: (() -> Int?)?

    /// Fires (status, optional message) whenever the connection state changes.
    var onStatusChanged: ((TvStatus, String?) -> Void)?
    /// Fires after a successful pairing with a new client-key to persist.
    var onClientKeyUpdated: ((String) -> Void)?
    /// Fires when the TV's current backlight is read, so the UI can sync the slider.
    var onBacklightReported: ((Int) -> Void)?
    /// Fires after the TV's MAC address is learned via ARP, so it can be persisted for WoL.
    var onMacAddressResolved: ((String) -> Void)?
    /// Fires when the TV reports a new power state ("Active", "Screen Off", "Suspend", …).
    var onPowerStateReported: ((String) -> Void)?

    init(device: TvDevice) {
        self.device = device
    }

    private func setStatus(_ s: TvStatus, _ message: String? = nil) {
        status = s
        onStatusChanged?(s, message)
    }

    /// Connects and pairs, retrying with backoff until disposed.
    func start() {
        gate.lock()
        let alreadyRunning = connectTask != nil
        gate.unlock()
        if alreadyRunning || disposed { return }

        // Detached: the loop must run on the global executor, never the caller's actor.
        let task = Task.detached { [weak self] () -> Void in
            guard let self else { return }
            await self.runConnectLoop()
        }
        gate.lock()
        connectTask = task
        gate.unlock()
    }

    private func runConnectLoop() async {
        var delay: TimeInterval = 1
        while !Task.isCancelled {
            do {
                setStatus(.connecting)
                let client = try await connectWithFallback()

                if device.clientKey.isEmpty {
                    setStatus(.awaitingPairing, "Accept the prompt on your TV")
                }

                let key = try await client.register(clientKey: device.clientKey.isEmpty ? nil : device.clientKey)
                if !key.isEmpty && key != device.clientKey {
                    device.clientKey = key
                    onClientKeyUpdated?(key)
                }

                setStatus(.connected)
                delay = 1 // reset backoff on success

                resolveMacInBackground()
                await readBacklight()
                applyMissedBacklightIfAny() // after the read, so the catch-up value wins

                // Schedule catch-up: once per session, after the read, apply the in-effect value.
                if !startupApplied {
                    startupApplied = true
                    if let target = getStartupBrightness?() {
                        device.lastBacklight = target
                        onBacklightReported?(target) // sync the slider
                        setBacklight(target)         // push to the TV
                    }
                }

                // Stay alive until the socket drops or we're disposed.
                await waitWhileConnected()
            } catch is CancellationError {
                break
            } catch {
                if Task.isCancelled { break }
                Log.write("\(device.host): connect cycle failed: \(error.localizedDescription)")
                setStatus(.error, error.localizedDescription)
            }

            cleanupClient()
            if Task.isCancelled { break }

            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { break }
            delay = min(delay * 2, 15) // exponential backoff, capped at 15s
        }
    }

    // webOS uses plain ws://:3000 on older firmware and secure wss://:3001 on newer
    // (2022+) models. Try the remembered transport first, then the other.
    private func connectWithFallback() async throws -> WebOSClient {
        let transports: [(port: Int, secure: Bool)] = device.secure
            ? [(3001, true), (3000, false)]
            : [(3000, false), (3001, true)]

        var last: Error?
        for (port, secure) in transports {
            try Task.checkCancellation()
            do {
                let client = WebOSClient(host: device.host)
                self.client = client
                client.onDisconnected = { [weak self] in self?.onClientDisconnected() }

                try await client.connect(port: port, secure: secure, timeout: 6)

                device.secure = secure // remember what worked for next time
                Log.write("Connected to \(device.host) via \(secure ? "wss" : "ws"):\(port)")
                return client
            } catch {
                last = error
                cleanupClient()
            }
        }

        throw WebOSError.tvError(
            "Can't reach the TV at \(device.host) on port 3000 or 3001. " +
            "Check the IP, that the TV is on, and that network/mobile control is enabled. " +
            (last.map { "(\($0.localizedDescription))" } ?? ""))
    }

    // Stays parked while the socket is healthy. A TV that loses power (or has its HDMI signal
    // cut and powers itself off) doesn't close the socket — TCP can take minutes to notice —
    // so poll the TV periodically and treat silence as a drop. Without this the UI reports
    // "Connected" long after the TV is gone, and commands vanish into a dead socket.
    private func waitWhileConnected() async {
        var sinceProbe = 0
        while !Task.isCancelled, let client, client.isConnected {
            do { try await Task.sleep(nanoseconds: 500_000_000) }
            catch { return }

            sinceProbe += 1
            if sinceProbe < Self.heartbeatSeconds * 2 { continue }
            sinceProbe = 0

            if await getPowerState() == nil,
               !Task.isCancelled,
               let client = self.client, client.isConnected {
                Log.write("\(device.host): heartbeat got no reply — dropping stale socket")
                dropStaleClient()
            }
        }
    }

    private func onClientDisconnected() {
        if !disposed {
            setStatus(.disconnected, "Reconnecting…")
        }
    }

    // MARK: - Brightness

    /// Queues a backlight change; only the latest value within the debounce window is sent.
    func setBacklight(_ value: Int) {
        let value = max(0, min(100, value))
        device.lastBacklight = value
        gate.lock()
        pendingValue = value
        hasPending = true
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { await self.flush() }
        }
        debounceItem = item
        gate.unlock()
        debounceQueue.asyncAfter(deadline: .now() + .milliseconds(Self.debounceMs), execute: item)
    }

    // Sync helpers so async code never calls NSLock directly.
    private func takePendingValue() -> Int? {
        gate.lock(); defer { gate.unlock() }
        guard hasPending else { return nil }
        hasPending = false
        return pendingValue
    }

    private func setMissed(_ value: Int?) {
        gate.lock(); defer { gate.unlock() }
        missedWhileOff = value
    }

    private func flush() async {
        guard let value = takePendingValue() else { return }

        // Off/unreachable TVs can't take the write — remember it so the TV "wakes up with"
        // the value it should have had (e.g. a schedule that fired while the panel slept).
        let knownOff = lastPowerState.map { !Self.isAwakeState($0) } ?? false
        guard let client, client.isConnected, !knownOff else {
            setMissed(value)
            Log.write("\(device.host): TV is off — holding brightness \(value) until it's back")
            return
        }

        // OLED Light is the "backlight" key in the picture category. Setting it requires
        // the privileged luna call routed through the alert API (see WebOSClient).
        let params: [String: Any] = [
            "category": "picture",
            "settings": ["backlight": String(value)]
        ]

        do {
            let resp = try await client.lunaRequest(SsapPayloads.lunaSetSystemSettings, params: params,
                                                    timeout: Self.requestTimeout)
            let ok = resp["returnValue"] as? Bool ?? false
            if !ok { Log.write("setBacklight \(value) rejected by TV: \(resp)") }
            setMissed(nil) // delivered — nothing left to catch up
        } catch {
            // The socket died mid-write; keep the value for when the TV returns.
            setMissed(value)
            Log.write("setBacklight \(value) FAILED (\(error.localizedDescription)) — holding until the TV is back")
        }
    }

    // Pushes a brightness value that a schedule (or the user) set while the TV was off.
    private func applyMissedBacklightIfAny() {
        gate.lock()
        let missed = missedWhileOff
        missedWhileOff = nil
        gate.unlock()
        if let value = missed {
            Log.write("\(device.host): TV is back — applying held brightness \(value)")
            device.lastBacklight = value
            onBacklightReported?(value) // sync the slider
            setBacklight(value)          // push to the TV
        }
    }

    private func readBacklight() async {
        guard let client, client.isConnected else { return }
        let payload: [String: Any] = ["category": "picture", "keys": ["backlight"]]
        do {
            let resp = try await client.request(SsapPayloads.getSystemSettings, payload: payload,
                                                timeout: Self.requestTimeout)
            let settings = resp["settings"] as? [String: Any]
            let raw = settings?["backlight"]
            let value = (raw as? Int) ?? (raw as? String).flatMap(Int.init)
            if let value {
                device.lastBacklight = value
                onBacklightReported?(value)
            }
        } catch { /* non-fatal: keep last-known value */ }
    }

    // MARK: - Power

    /// Turns the TV fully off. Returns false if it isn't connected or the TV refused.
    @discardableResult
    func turnOff() async -> Bool {
        guard let client, client.isConnected else { return false }
        do {
            let resp = try await client.request(SsapPayloads.turnOff, timeout: Self.requestTimeout)
            let ok = resp["returnValue"] as? Bool ?? true
            Log.write("\(device.host): turnOff -> \(ok ? "ok" : String(describing: resp))")
            return ok
        } catch {
            Log.write("\(device.host): turnOff FAILED: \(error.localizedDescription)")
            return false
        }
    }

    /// How a power request ended — what matters is whether the TV answered at all,
    /// since an error reply still proves it's awake and the socket is live.
    private enum TvReply { case ok, refused, unreachable }

    /// Blanks the panel ("screen off") — webOS keeps running so the picture returns instantly.
    @discardableResult
    func screenOff() async -> Bool {
        await screenCommand(SsapPayloads.turnOffScreen, legacy: SsapPayloads.turnOffScreenLegacy) == .ok
    }

    /// Un-blanks the panel after `screenOff()`.
    @discardableResult
    func screenOn() async -> Bool {
        await screenCommand(SsapPayloads.turnOnScreen, legacy: SsapPayloads.turnOnScreenLegacy) == .ok
    }

    // Screen on/off moved services across firmware generations; try current then legacy.
    // Each attempt is capped, because a TV that died while the socket still looked open
    // would otherwise never answer at all.
    private func screenCommand(_ uri: String, legacy: String) async -> TvReply {
        guard let client, client.isConnected else { return .unreachable }

        var answered = false
        for u in [uri, legacy] {
            do {
                let resp = try await client.request(u, payload: ["standbyMode": "active"],
                                                    timeout: Self.requestTimeout)
                answered = true
                if resp["returnValue"] as? Bool ?? true {
                    Log.write("\(device.host): \(u) ok")
                    return .ok
                }
            } catch WebOSError.timedOut {
                Log.write("\(device.host): \(u) timed out") // no reply at all — socket is dead
            } catch {
                // The TV replied with an error (e.g. when the screen is already on).
                // That's a refusal, not a dead socket.
                answered = true
                Log.write("\(device.host): \(u) refused: \(error.localizedDescription)")
            }
        }
        return answered ? .refused : .unreachable
    }

    /// Asks the TV for its power state ("Active", "Screen Off", "Suspend", "Power Off").
    /// Returns nil when it doesn't answer within the timeout — which is exactly how we tell
    /// a live socket from one that's open but dead.
    private func getPowerState() async -> String? {
        guard let client, client.isConnected else { return nil }
        do {
            let resp = try await client.request(SsapPayloads.getPowerState, timeout: Self.requestTimeout)
            guard let state = resp["state"] as? String else { return nil }
            if state != lastPowerState {
                // With Quick Start+ the socket often survives standby, so there is no
                // reconnect to hook — this transition is where an off TV "comes back".
                let wasOff = lastPowerState.map { !Self.isAwakeState($0) } ?? false
                lastPowerState = state
                Log.write("\(device.host): powerState = \(state)")
                onPowerStateReported?(state)
                if wasOff && Self.isAwakeState(state) { applyMissedBacklightIfAny() }
            }
            return state
        } catch {
            return nil
        }
    }

    /// True for a state in which the panel is lit or can be lit without a full power-on.
    /// Careful with the names: "Active" and "Screen Off" are awake, but "Active Standby" —
    /// what newer firmware (e.g. C3) reports in Quick Start+ standby — is OFF, as are the
    /// older "Suspend" / "Power Off".
    private static func isAwakeState(_ state: String) -> Bool {
        let lower = state.lowercased()
        return !lower.contains("standby") && !lower.contains("suspend") && !lower.contains("power off")
    }

    /// Powers the TV on, retrying until it answers.
    ///
    /// Neither wake path is trustworthy alone. The TV may only have its panel blanked, in
    /// which case screen-on is what's needed. But it may instead have powered itself off
    /// after the Mac stopped driving the HDMI output ("no signal"), and that leaves our
    /// socket open-but-dead for minutes. So we ask the TV what state it's in: an answer
    /// proves the socket is live and tells us whether to un-blank; silence means the socket
    /// is stale and only Wake-on-LAN will do. WoL is harmless to a TV that's already awake,
    /// so it goes out on every attempt.
    func powerOn() async {
        let hasMac = !device.macAddress.isEmpty
        if !hasMac && !(client?.isConnected ?? false) {
            Log.write("\(device.host): can't wake — MAC address not learned yet")
            return
        }

        for _ in 0..<Self.wakeAttempts {
            if Task.isCancelled { return }
            if hasMac { await WakeOnLan.send(mac: device.macAddress) }

            if let client, client.isConnected {
                let state = await getPowerState()
                if state == nil {
                    Log.write("\(device.host): no reply to getPowerState — stale socket, reconnecting")
                    dropStaleClient()
                } else if state!.lowercased().contains("screen off") {
                    await screenOn()
                    return
                } else if Self.isAwakeState(state!) {
                    return // already awake — nothing to do
                }
                // Any other state (Suspend / Power Off) means the TV is going down or
                // already down: keep the WoL retries coming.
            }

            do { try await Task.sleep(nanoseconds: UInt64(Self.wakeRetryDelay * 1_000_000_000)) }
            catch { return }

            if let client, client.isConnected { return } // it came back on its own
        }
    }

    // Tears down a socket the TV is no longer answering on. The reconnect loop is parked in
    // waitWhileConnected, which exits as soon as the client is gone.
    private func dropStaleClient() {
        cleanupClient()
        if !disposed { setStatus(.disconnected, "Reconnecting…") }
    }

    /// Turns the TV off if it's awake, wakes it if it isn't. Decided from the TV's own
    /// reported state rather than the socket flag, which keeps saying "connected" for
    /// minutes after a TV disappears.
    func togglePower() async {
        let state = await getPowerState()
        if let state, Self.isAwakeState(state) {
            await turnOff()
            return
        }

        if state == nil, let client, client.isConnected { dropStaleClient() }
        await powerOn()
    }

    /// True when the TV can be woken over the network (MAC already learned).
    var canWake: Bool { !device.macAddress.isEmpty }

    // Learn the TV's MAC once per device while it's reachable, so WoL works after it goes
    // off. Asks the TV itself over SSAP first (connectionmanager/getinfo — immune to macOS
    // local-network privacy hiding the ARP table), storing both the Wi-Fi and wired MACs;
    // the magic packet later goes to each. ARP is the fallback for firmware without getinfo.
    private func resolveMacInBackground() {
        guard device.macAddress.isEmpty else { return }
        let host = device.host
        let client = client
        Task.detached(priority: .utility) { [weak self] in
            guard let self, !self.disposed else { return }

            var mac: String?
            if let client, client.isConnected,
               let resp = try? await client.request(SsapPayloads.getConnectionInfo,
                                                    timeout: Self.requestTimeout) {
                let macs = ["wifiInfo", "wiredInfo"].compactMap {
                    ((resp[$0] as? [String: Any])?["macAddress"] as? String)?.uppercased()
                }
                if !macs.isEmpty { mac = macs.joined(separator: ",") }
            }
            mac = mac ?? WakeOnLan.tryResolveMac(host: host)

            guard let mac, !self.disposed else { return }
            self.device.macAddress = mac
            Log.write("\(host): MAC learned \(mac)")
            self.onMacAddressResolved?(mac)
        }
    }

    private func cleanupClient() {
        if let client {
            client.onDisconnected = nil
            client.dispose()
            self.client = nil
        }
        // Unknown until the next connection reports it; a stale "Suspend" would wrongly
        // divert post-reconnect writes into the catch-up holding slot.
        lastPowerState = nil
    }

    func dispose() {
        disposed = true
        connectTask?.cancel()
        connectTask = nil
        gate.lock()
        debounceItem?.cancel()
        debounceItem = nil
        gate.unlock()
        cleanupClient()
    }
}
