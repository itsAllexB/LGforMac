import Foundation

/// Hidden command-line mode for diagnostics — exercises the exact production services
/// without the UI. Not shown in any help; used for development and troubleshooting.
///
///   LGforMac --scan                 SSDP-discover TVs on the LAN
///   LGforMac --probe <host>         connect, pair (stored key if known), report state
///   LGforMac --set <host> <0-100>   connect, pair, set OLED Light
enum CliMode {
    static var isRequested: Bool {
        let args = CommandLine.arguments
        return args.count >= 2
            && ["--scan", "--probe", "--set", "--mac", "--raw", "--osd-preview"].contains(args[1])
    }

    static func runIfRequested() async -> Bool {
        let args = CommandLine.arguments
        guard args.count >= 2 else { return false }

        switch args[1] {
        case "--scan":
            print("Scanning for LG webOS TVs (about 4 s)…")
            let tvs = await SsdpDiscovery.findTvs { tv in
                print("  found: \(tv.name)  \(tv.host)  \(tv.model)")
            }
            print("\(tvs.count) TV(s) found.")
            return true

        case "--probe" where args.count >= 3:
            await probe(host: args[2], setValue: nil)
            return true

        case "--set" where args.count >= 4:
            await probe(host: args[2], setValue: Int(args[3]))
            return true

        case "--mac" where args.count >= 3:
            print(WakeOnLan.tryResolveMac(host: args[2]) ?? "MAC not resolved")
            return true

        case "--raw" where args.count >= 4:
            await raw(host: args[2], uri: args[3])
            return true

        case "--osd-preview":
            // Asks a RUNNING LGforMac app to show the OSD preview (test/debug hook).
            DistributedNotificationCenter.default().post(
                name: .init("com.itsallexb.LGforMac.osd-preview"), object: nil)
            try? await Task.sleep(nanoseconds: 300_000_000) // let the notification deliver
            print("preview requested")
            return true

        default:
            return false
        }
    }

    private static func raw(host: String, uri: String) async {
        let store = DeviceStore()
        let device = store.loadDevices().first { $0.host.caseInsensitiveCompare(host) == .orderedSame }
        guard let device, !device.clientKey.isEmpty else {
            print("host not paired yet — run --probe first")
            return
        }
        let client = WebOSClient(host: host)
        do {
            try await client.connect(port: device.secure ? 3001 : 3000, secure: device.secure)
            _ = try await client.register(clientKey: device.clientKey)
            let resp = try await client.request(uri, timeout: 5)
            let data = try JSONSerialization.data(withJSONObject: resp, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            print("error: \(error.localizedDescription)")
        }
        client.dispose()
    }

    private static func probe(host: String, setValue: Int?) async {
        // Reuse a stored client key when this host is already added in the app.
        let store = DeviceStore()
        let devices = store.loadDevices()
        let known = devices.first { $0.host.caseInsensitiveCompare(host) == .orderedSame }
        let device = known ?? TvDevice(name: "probe", host: host)

        let controller = TvController(device: device)
        let done = AsyncStream<Bool>.makeStream()

        controller.onStatusChanged = { status, message in
            switch status {
            case .connecting: print("connecting to \(host)…")
            case .awaitingPairing: print("PAIRING: accept the prompt on the TV now")
            case .connected:
                print("connected (\(device.secure ? "wss:3001" : "ws:3000"))")
                done.continuation.yield(true)
            case .error: print("error: \(message ?? "?")"); done.continuation.yield(false)
            case .disconnected: break
            }
        }
        controller.onBacklightReported = { value in print("backlight = \(value)") }
        controller.onPowerStateReported = { state in print("powerState = \(state)") }
        controller.onMacAddressResolved = { mac in print("mac = \(mac)") }
        controller.onClientKeyUpdated = { key in
            print("client-key = \(key)")
            if known != nil { store.saveDevices(devices) } // persist re-pair for the app
        }

        controller.start()

        var ok = false
        for await result in done.stream { ok = result; break }
        guard ok else { controller.dispose(); return }

        if let value = setValue {
            print("setting backlight to \(value)…")
            controller.setBacklight(value)
            try? await Task.sleep(nanoseconds: 1_500_000_000) // let the debounced write land
        } else {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // let MAC/power-state reports arrive
        }

        controller.dispose()
        print("done.")
    }
}
