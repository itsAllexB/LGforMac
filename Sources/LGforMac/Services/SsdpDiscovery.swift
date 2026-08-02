import Foundation

/// A TV found on the LAN via SSDP, ready to be added by one click.
struct DiscoveredTv: Identifiable, Hashable {
    let name: String
    let host: String
    let model: String
    var id: String { host }
}

/// Finds LG webOS TVs on the local network via SSDP (UPnP discovery). Sends an
/// M-SEARCH for the LG-specific "webos-second-screen" service — only webOS TVs
/// answer it — then fetches each responder's device-description XML for its
/// friendly name and model.
enum SsdpDiscovery {
    private static let multicastAddress = "239.255.255.250"
    private static let multicastPort: UInt16 = 1900
    private static let searchTarget = "urn:lge-com:service:webos-second-screen:1"

    private static let mSearch =
        "M-SEARCH * HTTP/1.1\r\n" +
        "HOST: \(multicastAddress):\(multicastPort)\r\n" +
        "MAN: \"ssdp:discover\"\r\n" +
        "MX: 2\r\n" +
        "ST: \(searchTarget)\r\n" +
        "\r\n"

    /// Scans for TVs for roughly `timeout` seconds (default 4), reporting each unique TV
    /// through `onFound` (on the main thread) as it answers, and returns the complete list.
    /// Never throws; an interface that can't be bound is simply skipped.
    static func findTvs(timeout: TimeInterval = 4,
                        onFound: (@MainActor (DiscoveredTv) -> Void)? = nil) async -> [DiscoveredTv] {
        let sockets = createSockets()
        guard !sockets.isEmpty else { return [] }
        defer { for fd in sockets { close(fd) } }

        // Fire the search a few times per socket — SSDP is UDP, replies can be lost.
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = multicastPort.bigEndian
        inet_pton(AF_INET, multicastAddress, &target.sin_addr)
        let search = Array(mSearch.utf8)

        let sendTask = Task.detached {
            for _ in 0..<3 {
                for fd in sockets {
                    search.withUnsafeBufferPointer { buf in
                        withUnsafePointer(to: target) { addr in
                            addr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                                _ = sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var results: [DiscoveredTv] = []
        var seenLocations = Set<String>()
        var seenHosts = Set<String>()

        // Listen on all sockets concurrently; each yields LOCATION urls as they arrive.
        await withTaskGroup(of: [String].self) { group in
            for fd in sockets {
                group.addTask { listen(on: fd, until: deadline) }
            }
            for await locations in group {
                for location in locations where seenLocations.insert(location).inserted {
                    guard let tv = await describe(location: location) else { continue }
                    if seenHosts.insert(tv.host).inserted {
                        results.append(tv)
                        if let onFound {
                            await MainActor.run { onFound(tv) }
                        }
                    }
                }
            }
        }

        sendTask.cancel()
        return results
    }

    // Blocking receive loop on one socket until the scan window closes (SO_RCVTIMEO-paced).
    private static func listen(on fd: Int32, until deadline: Date) -> [String] {
        var locations: [String] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { continue } // timeout tick or transient error — keep waiting
            let response = String(decoding: buffer[0..<n], as: UTF8.self)
            if let location = parseLocation(response) {
                locations.append(location)
            }
        }
        return locations
    }

    // One socket per IPv4 interface address (so multi-NIC machines search every subnet),
    // plus a wildcard socket as a catch-all. Each has a short receive timeout so the
    // listen loop can observe the deadline.
    private static func createSockets() -> [Int32] {
        var sockets: [Int32] = []

        func tryAdd(bindAddress: in_addr?) {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return }

            var tv = timeval(tv_sec: 0, tv_usec: 300_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var bufSize: Int32 = 64 * 1024
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr = bindAddress ?? in_addr(s_addr: INADDR_ANY)
            let bound = withUnsafePointer(to: addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { close(fd); return }

            // Route the multicast M-SEARCH out this specific interface.
            if var iface = bindAddress {
                setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &iface, socklen_t(MemoryLayout<in_addr>.size))
            }
            sockets.append(fd)
        }

        for address in NetworkInterfaces.ipv4Addresses() {
            tryAdd(bindAddress: address)
        }
        tryAdd(bindAddress: nil)
        return sockets
    }

    private static func parseLocation(_ response: String) -> String? {
        for line in response.components(separatedBy: "\r\n") {
            if line.uppercased().hasPrefix("LOCATION:") {
                let value = String(line.dropFirst("LOCATION:".count)).trimmingCharacters(in: .whitespaces)
                return URL(string: value)?.scheme != nil ? value : nil
            }
        }
        return nil
    }

    // Fetches the UPnP device description and turns it into a DiscoveredTv.
    private static func describe(location: String) async -> DiscoveredTv? {
        guard let url = URL(string: location), let host = url.host else { return nil }
        var name = "", model = ""
        if let (data, _) = try? await URLSession.shared.data(from: url) {
            let xml = String(decoding: data, as: UTF8.self)
            name = firstTag("friendlyName", in: xml) ?? ""
            model = firstTag("modelName", in: xml) ?? ""
        }

        // friendlyName is usually "[LG] webOS TV OLED55C34LA" — trim the boilerplate.
        name = name
            .replacingOccurrences(of: "[LG]", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "webOS TV", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = model.isEmpty ? "LG TV" : model }

        return DiscoveredTv(name: name, host: host, model: model)
    }

    private static func firstTag(_ tag: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(tag)>"),
              let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex) else { return nil }
        let value = String(xml[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// Shared interface enumeration helpers (SSDP + Wake-on-LAN).
enum NetworkInterfaces {
    /// IPv4 addresses of every up, non-loopback interface.
    static func ipv4Addresses() -> [in_addr] {
        addresses(keyPath: \.ifa_addr)
    }

    /// IPv4 broadcast addresses of every up, non-loopback interface.
    static func broadcastAddresses() -> [in_addr] {
        addresses(keyPath: \.ifa_dstaddr)
    }

    private static func addresses(keyPath: KeyPath<ifaddrs, UnsafeMutablePointer<sockaddr>?>) -> [in_addr] {
        var result: [in_addr] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let sa = entry.pointee[keyPath: keyPath], sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            if !result.contains(where: { $0.s_addr == addr.s_addr }) {
                result.append(addr)
            }
        }
        return result
    }
}
