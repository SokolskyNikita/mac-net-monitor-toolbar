import Darwin
import Foundation

enum LocalProbeMethod: String, CaseIterable {
    case icmp, dns, tcp443, tcp80, dhcp
    var label: String {
        switch self {
        case .icmp: return "ICMP"
        case .dns: return "DNS"
        case .tcp443: return "TCP 443"
        case .tcp80: return "TCP 80"
        case .dhcp: return "DHCP INFORM"
        }
    }
}

struct LocalProbeResult {
    var method: LocalProbeMethod
    var outcome: Latency.PingOutcome
}

/// Owns active measurements and preferred-protocol trials. Poll once per second;
/// active samples retain their three-second cadence and trials never enter health history.
/// All socket work stays on the caller's worker, with no sleeps or queued bursts.
final class LocalProbeSession {
    private let config: MonitoringConfig
    private let jitter: () -> Double
    init(config: MonitoringConfig = Configuration.monitoring,
         jitter: @escaping () -> Double = { Double.random(in: -1...1) }) {
        self.config = config; self.jitter = jitter
    }
    private let lock = NSLock()
    private var router: LocalRouter?
    private var epoch: Int?
    private var selected: LocalProbeMethod?
    private var failures = 0
    private var nextDiscovery: TimeInterval = 0
    private var nextMeasurement: TimeInterval = 0
    private struct Retry {
        var next: TimeInterval
        var attempt = 0
        var replies = 0
    }
    private var retries: [LocalProbeMethod: Retry] = [:]
    private var probation: (previous: LocalProbeMethod, until: TimeInterval)?

    private func prepare(_ router: LocalRouter, epoch: Int) {
        if self.router != router || self.epoch != epoch {
            self.router = router; self.epoch = epoch
            selected = nil; failures = 0; nextDiscovery = 0; nextMeasurement = 0
            retries.removeAll(); probation = nil
        }
    }

    /// The live scheduler calls this on its one-second tick. Only active measurements
    /// are returned; confirmation probes can run on intervening ticks.
    func poll(_ router: LocalRouter, epoch: Int = 0, now: TimeInterval = HealthTracker.now(),
              probe: (LocalProbeMethod, LocalRouter) -> Latency.PingOutcome = LocalProtocols.probe) -> LocalProbeResult? {
        lock.lock(); defer { lock.unlock() }
        prepare(router, epoch: epoch)
        var result: LocalProbeResult?
        if now >= nextMeasurement {
            nextMeasurement = now + config.probeInterval
            result = measureLocked(router, now: now, probe: probe)
        }
        retryPreferred(router, now: now, probe: probe)
        return result
    }

    /// Explicit single measurements (also useful for diagnostics and deterministic tests).
    func measure(_ router: LocalRouter, epoch: Int = 0, now: TimeInterval = HealthTracker.now(),
                 probe: (LocalProbeMethod, LocalRouter) -> Latency.PingOutcome = LocalProtocols.probe) -> LocalProbeResult {
        lock.lock(); defer { lock.unlock() }
        prepare(router, epoch: epoch)
        return measureLocked(router, now: now, probe: probe)
    }

    private func delay(_ attempt: Int) -> TimeInterval {
        let delays = config.localRetryDelays
        let base = delays.isEmpty ? config.localDiscoveryInterval : delays[min(attempt, delays.count - 1)]
        return base * (1 + config.localRetryJitter * jitter())
    }

    private func schedulePreferred(before method: LocalProbeMethod, now: TimeInterval) {
        for candidate in LocalProbeMethod.allCases.prefix(while: { $0 != method }) where retries[candidate] == nil {
            retries[candidate] = Retry(next: now + delay(0), attempt: 1)
        }
    }

    private func backoff(_ method: LocalProbeMethod, now: TimeInterval) {
        var retry = retries[method] ?? Retry(next: now)
        retry.replies = 0
        retry.next = now + delay(retry.attempt)
        retry.attempt += 1
        retries[method] = retry
    }

    private func select(_ method: LocalProbeMethod, now: TimeInterval) {
        selected = method; failures = 0
        schedulePreferred(before: method, now: now)
    }

    private func measureLocked(_ router: LocalRouter, now: TimeInterval,
                               probe: (LocalProbeMethod, LocalRouter) -> Latency.PingOutcome) -> LocalProbeResult {
        if let p = probation, now >= p.until { probation = nil }
        let method = selected ?? .icmp
        let outcome = probe(method, router)
        let result = LocalProbeResult(method: method, outcome: outcome)
        if case .reply = outcome {
            select(method, now: now)
            return result
        }
        failures += 1
        // Any active failure interrupts a qualification burst. Trials only run while stable.
        for candidate in Array(retries.keys) where retries[candidate]!.replies > 0 {
            backoff(candidate, now: now)
        }
        if let p = probation, failures >= config.localProbationFailureLimit {
            probation = nil
            backoff(method, now: now)
            select(p.previous, now: now)
            return result // Keep the second failure in health history, even on rollback.
        }
        if now >= nextDiscovery, selected == nil || failures >= config.localFailureLimit {
            nextDiscovery = now + config.localDiscoveryInterval
            let wasSelected = selected != nil
            for candidate in LocalProbeMethod.allCases where candidate != method {
                let fallback = probe(candidate, router)
                if case .reply = fallback {
                    probation = nil
                    select(candidate, now: now)
                    // Discovery must not replace an established method's failed sample.
                    return wasSelected ? result : .init(method: candidate, outcome: fallback)
                }
            }
        }
        return result
    }

    private func retryPreferred(_ router: LocalRouter, now: TimeInterval,
                                probe: (LocalProbeMethod, LocalRouter) -> Latency.PingOutcome) {
        guard let active = selected, failures == 0, probation == nil else { return }
        let preferred = LocalProbeMethod.allCases.prefix(while: { $0 != active })
        // Finish a successful burst before spending time on another candidate.
        guard let candidate = preferred.first(where: { (retries[$0]?.replies ?? 0) > 0 })
            ?? preferred.first(where: { (retries[$0]?.next ?? .infinity) <= now }),
              var retry = retries[candidate], now >= retry.next else { return }
        guard case .reply = probe(candidate, router) else {
            backoff(candidate, now: now)
            return
        }
        retry.replies += 1
        if retry.replies >= config.localConfirmationCount {
            retries.removeValue(forKey: candidate)
            select(candidate, now: now)
            probation = (active, now + config.localProbationInterval)
        } else {
            retry.next = now + config.localConfirmationInterval
            retries[candidate] = retry
        }
    }
}

/// Small direct-to-router exchanges. DNS disables recursion and asks about the root,
/// TCP sends no application data, and DHCPINFORM neither requests nor renews a lease.
/// Never broadcast, talk to an off-router DHCP/DNS server, or reuse the OS DHCP socket.
enum LocalProtocols {
    static let timeoutMs = Configuration.monitoring.localTimeoutMs

    static func probe(_ method: LocalProbeMethod, _ router: LocalRouter) -> Latency.PingOutcome {
        switch method {
        case .icmp: return Latency.ping(router.address, timeoutMs: timeoutMs)
        case .dns:
            let request = DNSProbe.request(id: UInt16.random(in: 0...UInt16.max))
            return exchange(router, port: 53, request: request) { DNSProbe.matches($0, request: request) }
        case .tcp443: return tcp(router, port: 443)
        case .tcp80: return tcp(router, port: 80)
        case .dhcp:
            guard !router.address.contains(":"), let client = DHCPProbe.client(interface: router.interface) else {
                return .unmeasured("DHCP INFORM requires an IPv4 client address and Ethernet MAC")
            }
            let request = DHCPProbe.request(client: client, xid: UInt32.random(in: 0...UInt32.max))
            return exchange(router, port: 67, request: request, client: client) {
                DHCPProbe.matches($0, request: request, server: router.address)
            }
        }
    }

    private static func withSocket(_ router: LocalRouter, port: UInt16, type: Int32,
                                   work: (Int32, UnsafeMutablePointer<addrinfo>) -> Latency.PingOutcome) -> Latency.PingOutcome {
        var hints = addrinfo()
        hints.ai_family = router.address.contains(":") ? AF_INET6 : AF_INET
        hints.ai_socktype = type; hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(router.address, String(port), &hints, &result) == 0, let address = result else {
            return .unmeasured("invalid router address")
        }
        defer { freeaddrinfo(result) }
        let fd = socket(hints.ai_family, type, 0)
        guard fd >= 0 else { return .unmeasured("local socket unavailable") }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var index = if_nametoindex(router.interface)
        guard index != 0 else { return .unmeasured("interface unavailable") }
        let v6 = hints.ai_family == AF_INET6
        guard setsockopt(fd, v6 ? IPPROTO_IPV6 : IPPROTO_IP, v6 ? IPV6_BOUND_IF : IP_BOUND_IF,
                         &index, socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
            return .unmeasured("cannot bind probe to local interface")
        }
        var hopLimit: Int32 = 1
        guard setsockopt(fd, v6 ? IPPROTO_IPV6 : IPPROTO_IP, v6 ? IPV6_UNICAST_HOPS : IP_TTL,
                         &hopLimit, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            return .unmeasured("cannot limit probe to local link")
        }
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_TIMESTAMP, &on, socklen_t(MemoryLayout<Int32>.size))
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return .unmeasured("cannot make socket nonblocking") }
        return work(fd, address)
    }

    static func tcp(_ router: LocalRouter, port: UInt16) -> Latency.PingOutcome {
        withSocket(router, port: port, type: SOCK_STREAM) { fd, address in
            let start = HealthTracker.now()
            let status = connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen)
            var error = status == 0 ? 0 : errno
            if error == EINPROGRESS {
                let ready = wait(fd, events: Int16(POLLOUT), deadline: start + Double(timeoutMs) / 1000)
                if ready == 0 { return .lost }
                if ready < 0 { return .unmeasured("TCP wait failed") }
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else { return .unmeasured("TCP status unavailable") }
            }
            // An explicit refusal is also a response from the directly addressed router.
            if error == 0 || error == ECONNREFUSED {
                return .reply(.init(ms: (HealthTracker.now() - start) * 1000, hops: nil))
            }
            return failure(error)
        }
    }

    static func exchange(_ router: LocalRouter, port: UInt16, request: [UInt8], client: DHCPProbe.Client? = nil,
                         matches: ([UInt8]) -> Bool) -> Latency.PingOutcome {
        withSocket(router, port: port, type: SOCK_DGRAM) { fd, address in
            if let client {
                var local = sockaddr_in()
                local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); local.sin_family = sa_family_t(AF_INET)
                local.sin_port = UInt16(68).bigEndian
                local.sin_addr.s_addr = client.ip.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                let bound = withUnsafePointer(to: &local) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                // No SO_REUSEADDR/PORT: never compete with configd for DHCP replies.
                guard bound == 0 else { return .unmeasured("DHCP client port unavailable or owned by macOS") }
            }
            guard connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 else { return failure(errno) }
            var wall = timeval(); gettimeofday(&wall, nil)
            let start = HealthTracker.now(), deadline = start + Double(timeoutMs) / 1000
            guard send(fd, request, request.count, 0) == request.count else { return failure(errno) }
            while true {
                let ready = wait(fd, events: Int16(POLLIN), deadline: deadline)
                if ready == 0 { return .lost }
                if ready < 0 { return .unmeasured("UDP wait failed") }
                var bytes = [UInt8](repeating: 0, count: 4096), control = [UInt8](repeating: 0, count: 256)
                var iov = iovec(), msg = msghdr()
                let n = bytes.withUnsafeMutableBytes { buf in
                    control.withUnsafeMutableBytes { ctl in
                        withUnsafeMutablePointer(to: &iov) { ptr in
                            ptr.pointee = iovec(iov_base: buf.baseAddress, iov_len: buf.count)
                            msg.msg_iov = ptr; msg.msg_iovlen = 1
                            msg.msg_control = ctl.baseAddress; msg.msg_controllen = socklen_t(ctl.count)
                            return recvmsg(fd, &msg, MSG_DONTWAIT)
                        }
                    }
                }
                if n < 0 {
                    if [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { continue }
                    return failure(errno)
                }
                guard msg.msg_flags & MSG_TRUNC == 0, matches(Array(bytes.prefix(n))) else { continue }
                let mono = (HealthTracker.now() - start) * 1000
                var ms = mono
                if let stamp = ICMPPinger.timestamp(control: control, length: Int(msg.msg_controllen)) {
                    let kernel = Double(stamp.tv_sec - wall.tv_sec) * 1000 + Double(Int(stamp.tv_usec) - Int(wall.tv_usec)) / 1000
                    if kernel >= 0, kernel <= mono + 5 { ms = kernel }
                }
                return .reply(.init(ms: ms, hops: nil))
            }
        }
    }

    private static func wait(_ fd: Int32, events: Int16, deadline: TimeInterval) -> Int32 {
        while true {
            let remaining = deadline - HealthTracker.now()
            guard remaining > 0 else { return 0 }
            var p = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&p, 1, Int32(ceil(remaining * 1000)))
            if result < 0, errno == EINTR { continue }
            return result
        }
    }

    private static func failure(_ error: Int32) -> Latency.PingOutcome {
        if [EHOSTUNREACH, ENETUNREACH, ENETDOWN, EHOSTDOWN, ETIMEDOUT, ECONNREFUSED].contains(error) { return .lost }
        return .unmeasured("local socket: \(String(cString: strerror(error)))")
    }
}

// RFC 1035: a nonrecursive root SOA query. Any matching DNS response (including
// REFUSED/SERVFAIL) proves that the router answered; external DNS is never queried.
enum DNSProbe {
    static func request(id: UInt16) -> [UInt8] {
        [UInt8(id >> 8), UInt8(id & 255), 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 6, 0, 1]
    }
    static func matches(_ reply: [UInt8], request: [UInt8]) -> Bool {
        guard request.count == 17, reply.count >= 17 else { return false }
        return reply[0...1] == request[0...1] && reply[2] & 0xf8 == 0x80
            && reply[4] == 0 && reply[5] == 1 && reply[12...16] == request[12...16]
    }
}

// RFC 2131 §4.4.3. Read only configuration information; never apply the reply.
enum DHCPProbe {
    struct Client { var ip: [UInt8]; var mac: [UInt8] }
    static func client(interface: String) -> Client? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(first) }
        var ip: [UInt8]?, mac: [UInt8]?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard String(cString: item.pointee.ifa_name) == interface, let address = item.pointee.ifa_addr else { continue }
            if Int32(address.pointee.sa_family) == AF_INET {
                var value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
                let bytes = withUnsafeBytes(of: &value) { Array($0) }
                if bytes != [192, 0, 0, 2], bytes != [0, 0, 0, 0] { ip = bytes }
            } else if Int32(address.pointee.sa_family) == AF_LINK {
                let link = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_dl.self).pointee
                let offset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)! + Int(link.sdl_nlen)
                if link.sdl_alen == 6, offset + 6 <= Int(link.sdl_len) {
                    mac = Array(UnsafeBufferPointer(start: UnsafeRawPointer(address).advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: 6))
                }
            }
        }
        guard let ip, let mac else { return nil }
        return Client(ip: ip, mac: mac)
    }
    static func request(client: Client, xid: UInt32) -> [UInt8] {
        precondition(client.ip.count == 4 && client.mac.count == 6)
        var packet = [UInt8](repeating: 0, count: 240)
        packet[0] = 1; packet[1] = 1; packet[2] = 6
        packet.replaceSubrange(4..<8, with: [24, 16, 8, 0].map { UInt8((xid >> $0) & 255) })
        packet.replaceSubrange(12..<16, with: client.ip)
        packet.replaceSubrange(28..<34, with: client.mac)
        packet.replaceSubrange(236..<240, with: [99, 130, 83, 99])
        packet += [53, 1, 8, 55, 2, 1, 3, 255] // INFORM; request subnet mask and router only
        packet += Array(repeating: 0, count: max(0, 300 - packet.count))
        return packet
    }
    static func matches(_ reply: [UInt8], request: [UInt8], server: String) -> Bool {
        guard request.count >= 240, reply.count >= 240, reply[0] == 2, reply[1] == 1, reply[2] == 6,
              reply[4..<8] == request[4..<8], reply[28..<34] == request[28..<34],
              reply[236..<240] == [99, 130, 83, 99][...],
              reply[24..<28].allSatisfy({ $0 == 0 }) else { return false } // no relay
        var options: [UInt8: [UInt8]] = [:]
        var i = 240, ended = false
        while i < reply.count {
            let tag = reply[i]; i += 1
            if tag == 255 { ended = true; break }
            if tag == 0 { continue }
            guard i < reply.count else { return false }
            let count = Int(reply[i]); i += 1
            guard i + count <= reply.count, options[tag] == nil else { return false }
            options[tag] = Array(reply[i..<(i + count)]); i += count
        }
        let ip = server.split(separator: ".").compactMap { UInt8($0) }
        return ended && ip.count == 4 && options[53] == [5] && options[54] == ip
    }
}
