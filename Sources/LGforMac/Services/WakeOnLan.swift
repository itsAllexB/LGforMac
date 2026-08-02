import Foundation

/// Wake-on-LAN: resolves a TV's MAC address while it's reachable (ARP cache), and later
/// wakes it by broadcasting the magic packet. webOS TVs answer WoL when "Quick Start+" /
/// "Turn on via Wi-Fi" is enabled in the TV's settings.
enum WakeOnLan {
    /// Looks up the MAC address for a host on the local subnet from the system ARP cache
    /// (primed with a throwaway UDP datagram — while we're connected over TCP the entry
    /// exists anyway). Returns "AA:BB:CC:DD:EE:FF", or nil if it can't be resolved right
    /// now. Blocking (up to a couple of seconds) — call from a background thread.
    static func tryResolveMac(host: String) -> String? {
        guard let ip = resolveIPv4(host) else { Log.write("mac: resolveIPv4 failed for \(host)"); return nil }

        // Prime the ARP cache: any datagram forces the kernel to resolve the MAC.
        primeArp(ip: ip)
        usleep(150_000)

        // macOS has no SendARP equivalent; the supported way to read the ARP cache
        // without private headers is the arp(8) tool.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-n", ip]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            Log.write("mac: arp launch failed: \(error)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        Log.write("mac: arp exit=\(process.terminationStatus) output=[\(output.trimmingCharacters(in: .whitespacesAndNewlines))]")

        // "? (192.168.1.42) at ac:5a:f0:1:2:3 on en0 ifscope [ethernet]"
        guard let range = output.range(of: #" at ([0-9a-fA-F]{1,2}(?::[0-9a-fA-F]{1,2}){5}) "#,
                                       options: .regularExpression) else { return nil }
        let mac = output[range]
            .replacingOccurrences(of: " at ", with: "")
            .trimmingCharacters(in: .whitespaces)
        // arp(8) prints single-digit octets ("1" for "01") — normalize to two digits.
        let parts = mac.split(separator: ":").map { String(format: "%02X", UInt8($0, radix: 16) ?? 0) }
        guard parts.count == 6, parts.contains(where: { $0 != "00" }) else { return nil }
        return parts.joined(separator: ":")
    }

    /// Sends the WoL magic packet for `mac` ("AA:BB:CC:DD:EE:FF", or several separated by
    /// commas — the TV's Wi-Fi and wired MACs are both stored since either may be active),
    /// broadcast on every up network interface plus the global broadcast, a few times for
    /// reliability. Never throws.
    static func send(mac: String) async {
        for single in mac.split(separator: ",") {
            await sendSingle(mac: String(single).trimmingCharacters(in: .whitespaces))
        }
    }

    private static func sendSingle(mac: String) async {
        guard let bytes = parseMac(mac) else { return }

        // 6× 0xFF followed by the MAC repeated 16 times.
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }

        await Task.detached(priority: .utility) {
            var targets = NetworkInterfaces.broadcastAddresses()
            targets.append(in_addr(s_addr: INADDR_BROADCAST))

            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var enable: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enable, socklen_t(MemoryLayout<Int32>.size))

            for target in targets {
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = UInt16(9).bigEndian
                addr.sin_addr = target
                for _ in 0..<3 {
                    packet.withUnsafeBufferPointer { buf in
                        withUnsafePointer(to: addr) { ptr in
                            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                                _ = sendto(fd, buf.baseAddress, buf.count, 0, sa,
                                           socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                }
            }
        }.value

        Log.write("WoL sent to \(mac)")
    }

    private static func parseMac(_ mac: String) -> [UInt8]? {
        let parts = mac.split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard let byte = UInt8(part, radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }

    private static func resolveIPv4(_ host: String) -> String? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, let first = info else { return nil }
        defer { freeaddrinfo(info) }
        guard let sa = first.pointee.ai_addr else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var addr = sin.sin_addr
        guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buffer)
    }

    private static func primeArp(ip: String) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(9).bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)
        var byte: UInt8 = 0
        withUnsafePointer(to: addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = sendto(fd, &byte, 1, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}
